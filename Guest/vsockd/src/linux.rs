use crate::{
    ConnectionLimiter, PortMapping, COPY_BUFFER_BYTES, HOST_VSOCK_CID, MAX_CONNECTIONS_PER_PORT,
    PORT_MAPPINGS,
};
use std::{
    fs::File,
    io::{self, Read, Write},
    mem::{self, size_of},
    os::fd::{AsRawFd, FromRawFd},
    sync::atomic::Ordering,
    thread::{self, JoinHandle},
    time::Duration,
};

const VMADDR_CID_ANY: u32 = u32::MAX;
const LISTEN_BACKOFF: Duration = Duration::from_secs(1);

pub(super) fn run() -> io::Result<()> {
    let mut listeners: Vec<JoinHandle<()>> = Vec::with_capacity(PORT_MAPPINGS.len());
    for mapping in PORT_MAPPINGS {
        let listener = thread::Builder::new()
            .name(format!("vsock-listener-{}", mapping.port))
            .spawn(move || serve_port(mapping))?;
        listeners.push(listener);
    }

    for listener in listeners {
        if listener.join().is_err() {
            return Err(io::Error::other("vsock listener thread panicked"));
        }
    }
    Ok(())
}

fn serve_port(mapping: PortMapping) {
    let limiter = ConnectionLimiter::new(MAX_CONNECTIONS_PER_PORT, mapping.port);
    loop {
        let listener = match bind_listener(mapping.port) {
            Ok(listener) => {
                log::info!("listening on vsock port {}", mapping.port);
                listener
            }
            Err(error) => {
                log::error!(
                    "cannot bind vsock port {}: {:?}",
                    mapping.port,
                    error.kind()
                );
                thread::sleep(LISTEN_BACKOFF);
                continue;
            }
        };

        loop {
            match accept(&listener) {
                Ok((stream, peer_cid)) => {
                    dispatch_if_authorized(
                        stream,
                        peer_cid,
                        mapping,
                        |stream, connection_mapping| {
                            let Some(permit) = limiter.try_acquire() else {
                                let active = limiter.active.load(Ordering::Acquire);
                                log::warn!(
                                "closed excess connection on vsock port {} from CID {} (active {})",
                                connection_mapping.port,
                                peer_cid,
                                active
                            );
                                drop(stream);
                                return;
                            };
                            let active = limiter.active.load(Ordering::Acquire);
                            log::info!(
                                "accepted host CID {} on vsock port {} (active {}/{})",
                                peer_cid,
                                connection_mapping.port,
                                active,
                                MAX_CONNECTIONS_PER_PORT
                            );
                            if let Err(error) = thread::Builder::new()
                                .name(format!("vsock-connection-{}", connection_mapping.port))
                                .spawn(move || {
                                    let _permit = permit;
                                    handle_connection(stream, connection_mapping);
                                })
                            {
                                log::warn!(
                                    "cannot start bridge on vsock port {}: {:?}",
                                    mapping.port,
                                    error.kind()
                                );
                            }
                        },
                    );
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(error) => {
                    log::error!(
                        "accept failed on vsock port {}: {:?}",
                        mapping.port,
                        error.kind()
                    );
                    break;
                }
            }
        }
    }
}

fn is_authorized_host(peer_cid: u32) -> bool {
    peer_cid == HOST_VSOCK_CID
}

fn dispatch_if_authorized(
    stream: File,
    peer_cid: u32,
    mapping: PortMapping,
    dispatch: impl FnOnce(File, PortMapping),
) -> bool {
    if !is_authorized_host(peer_cid) {
        log::warn!(
            "refused vsock port {} from CID {} (expected {})",
            mapping.port,
            peer_cid,
            HOST_VSOCK_CID
        );
        drop(stream);
        return false;
    }

    dispatch(stream, mapping);
    true
}

fn handle_connection(vsock: File, mapping: PortMapping) {
    let agent = match connect_abstract(mapping.abstract_socket) {
        Ok(agent) => agent,
        Err(error) => {
            log::warn!(
                "cannot connect port {} to @{}: {:?}",
                mapping.port,
                mapping.abstract_socket,
                error.kind()
            );
            return;
        }
    };

    if let Err(error) = bridge(vsock, agent) {
        log::warn!(
            "bridge failed on vsock port {}: {:?}",
            mapping.port,
            error.kind()
        );
    }
}

fn bridge(left: File, right: File) -> io::Result<()> {
    let left_shutdown = left.try_clone()?;
    let right_shutdown = right.try_clone()?;
    let reverse_left_shutdown = left.try_clone()?;
    let reverse_right_shutdown = right.try_clone()?;
    let reverse_reader = right.try_clone()?;
    let reverse_writer = left.try_clone()?;

    let reverse: JoinHandle<io::Result<()>> = thread::Builder::new()
        .name("vsock-copy-reverse".to_owned())
        .spawn(move || {
            let result = copy_stream(reverse_reader, reverse_writer);
            shutdown_both(&reverse_left_shutdown, &reverse_right_shutdown);
            result
        })?;

    let forward_result = copy_stream(left, right);
    shutdown_both(&left_shutdown, &right_shutdown);
    let reverse_result = match reverse.join() {
        Ok(result) => result,
        Err(_) => Err(io::Error::other("reverse copy thread panicked")),
    };

    log_copy_result("host-to-agent", forward_result.as_ref().err());
    log_copy_result("agent-to-host", reverse_result.as_ref().err());
    forward_result.and(reverse_result)
}

fn copy_stream(mut reader: File, mut writer: File) -> io::Result<()> {
    let mut buffer = [0_u8; COPY_BUFFER_BYTES];
    loop {
        let bytes_read = reader.read(&mut buffer)?;
        if bytes_read == 0 {
            return Ok(());
        }
        writer.write_all(&buffer[..bytes_read])?;
    }
}

fn log_copy_result(direction: &str, error: Option<&io::Error>) {
    if let Some(error) = error {
        log::debug!("{} stream ended: {:?}", direction, error.kind());
    }
}

fn shutdown_both(left: &File, right: &File) {
    shutdown(left);
    shutdown(right);
}

fn shutdown(stream: &File) {
    // SAFETY: `stream` owns a live connected socket descriptor; shutdown only changes socket state.
    let result = unsafe { libc::shutdown(stream.as_raw_fd(), libc::SHUT_RDWR) };
    if result < 0 {
        let error = io::Error::last_os_error();
        log::debug!("socket shutdown ended: {:?}", error.kind());
    }
}

fn bind_listener(port: u32) -> io::Result<File> {
    let listener = socket(libc::AF_VSOCK)?;
    // SAFETY: zero is a valid initial representation for this C address structure.
    let mut address: libc::sockaddr_vm = unsafe { mem::zeroed() };
    address.svm_family = libc::AF_VSOCK as libc::sa_family_t;
    address.svm_port = port;
    address.svm_cid = VMADDR_CID_ANY;
    // SAFETY: `address` is fully initialized and `listener` is a live AF_VSOCK socket.
    let bind_result = unsafe {
        libc::bind(
            listener.as_raw_fd(),
            (&address as *const libc::sockaddr_vm).cast(),
            size_of::<libc::sockaddr_vm>() as libc::socklen_t,
        )
    };
    if bind_result < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `listener` is a live AF_VSOCK socket bound above.
    if unsafe {
        libc::listen(
            listener.as_raw_fd(),
            MAX_CONNECTIONS_PER_PORT as libc::c_int,
        )
    } < 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(listener)
}

fn accept(listener: &File) -> io::Result<(File, u32)> {
    // SAFETY: zero is a valid initial representation for this C address structure.
    let mut peer: libc::sockaddr_vm = unsafe { mem::zeroed() };
    let mut peer_len = size_of::<libc::sockaddr_vm>() as libc::socklen_t;
    // SAFETY: `listener` is live and the address buffer and length are writable and correctly sized.
    let fd = unsafe {
        libc::accept4(
            listener.as_raw_fd(),
            (&mut peer as *mut libc::sockaddr_vm).cast(),
            &mut peer_len,
            libc::SOCK_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: accept4 returned a new descriptor whose ownership transfers to this File.
    let stream = unsafe { File::from_raw_fd(fd) };
    if peer_len as usize != size_of::<libc::sockaddr_vm>()
        || peer.svm_family as libc::c_int != libc::AF_VSOCK
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "accepted peer is not a vsock address",
        ));
    }
    Ok((stream, peer.svm_cid))
}

fn connect_abstract(name: &str) -> io::Result<File> {
    let mut socket_address: libc::sockaddr_un = {
        // SAFETY: zero is a valid initial representation for sockaddr_un.
        unsafe { mem::zeroed() }
    };
    if name.is_empty() || name.len() + 1 > socket_address.sun_path.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "abstract socket name is empty or too long",
        ));
    }
    socket_address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (index, byte) in name.bytes().enumerate() {
        socket_address.sun_path[index + 1] = byte as libc::c_char;
    }
    let address_len = (size_of::<libc::sa_family_t>() + 1 + name.len()) as libc::socklen_t;
    let agent = socket(libc::AF_UNIX)?;
    // SAFETY: the NUL-prefixed abstract name and address length are valid for sockaddr_un.
    let result = unsafe {
        libc::connect(
            agent.as_raw_fd(),
            (&socket_address as *const libc::sockaddr_un).cast(),
            address_len,
        )
    };
    if result < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(agent)
}

fn socket(domain: libc::c_int) -> io::Result<File> {
    // SAFETY: socket is called with a supported domain, stream type, and default protocol.
    let fd = unsafe { libc::socket(domain, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: socket returned a new descriptor whose ownership transfers to this File.
    Ok(unsafe { File::from_raw_fd(fd) })
}

#[cfg(test)]
mod tests {
    use super::{is_authorized_host, HOST_VSOCK_CID};

    #[test]
    fn only_host_cid_two_is_authorized() {
        assert!(is_authorized_host(HOST_VSOCK_CID));
        assert!(
            !is_authorized_host(1),
            "loopback CID must not be authorized"
        );
        assert!(
            !is_authorized_host(3),
            "other guest CIDs must not be authorized"
        );
    }
}

#[cfg(all(test, feature = "vsock-loopback", target_os = "linux"))]
mod vsock_loopback_tests {
    use super::*;
    use std::{
        io::{Read, Write},
        os::fd::AsRawFd,
        time::Duration,
    };

    const LOOPBACK_CID: u32 = 1;
    const VMADDR_PORT_ANY: u32 = u32::MAX;

    #[test]
    #[ignore = "requires Linux AF_VSOCK loopback support in the guest test kernel"]
    fn vsock_loopback_refuses_non_host_cid_and_bridges_abstract_agent_sockets() {
        assert!(is_authorized_host(HOST_VSOCK_CID));
        assert!(!is_authorized_host(LOOPBACK_CID));
        assert!(!is_authorized_host(u32::MAX));

        assert_production_dispatch_refuses_loopback_peer();
        assert_vsock_abstract_socket_bridge_copies_in_both_directions();
    }

    fn assert_production_dispatch_refuses_loopback_peer() {
        let agent_name = format!("apkrun-vsock-loopback-auth-{}", std::process::id());
        let agent_listener =
            bind_abstract_listener(&agent_name).expect("bind abstract agent socket");
        set_nonblocking(&agent_listener).expect("make agent listener nonblocking");

        let listener = bind_listener(VMADDR_PORT_ANY).expect("bind production AF_VSOCK listener");
        let port = local_vsock_port(&listener).expect("read ephemeral AF_VSOCK port");
        let mut client = connect_vsock(LOOPBACK_CID, port)
            .expect("connect AF_VSOCK loopback client using CID 1");
        set_socket_timeout(&client, Duration::from_secs(3))
            .expect("set bounded loopback client timeout");

        let (server, peer_cid) = accept(&listener).expect("accept AF_VSOCK loopback peer");
        assert_eq!(
            peer_cid, LOOPBACK_CID,
            "Linux AF_VSOCK loopback must identify itself as CID 1"
        );

        let mut forwarded = false;
        let accepted = dispatch_if_authorized(
            server,
            peer_cid,
            PortMapping {
                port,
                abstract_socket: "unused-test-mapping",
            },
            |stream, _mapping| {
                forwarded = true;
                drop(stream);
                let upstream =
                    connect_abstract(&agent_name).expect("authorized dispatch reaches agent");
                drop(upstream);
            },
        );
        assert!(
            !accepted,
            "CID 1 must be refused by the production dispatch"
        );
        assert!(
            !forwarded,
            "a refused peer must not reach the agent connector"
        );
        assert!(
            matches!(
                accept_unix(&agent_listener),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock
            ),
            "a refused peer must not create an abstract-socket connection"
        );

        let mut byte = [0_u8; 1];
        assert_eq!(
            client.read(&mut byte).expect("read rejected peer closure"),
            0,
            "unauthorized CID 1 connection must be closed without bridging"
        );
    }

    fn assert_vsock_abstract_socket_bridge_copies_in_both_directions() {
        let vsock_listener =
            bind_listener(VMADDR_PORT_ANY).expect("bind AF_VSOCK loopback listener");
        let port = local_vsock_port(&vsock_listener).expect("read ephemeral AF_VSOCK port");
        let mut host_peer = connect_vsock(LOOPBACK_CID, port)
            .expect("connect AF_VSOCK loopback client using CID 1");
        set_socket_timeout(&host_peer, Duration::from_secs(3))
            .expect("set bounded VSOCK client timeout");
        let (bridge_vsock, peer_cid) =
            accept(&vsock_listener).expect("accept AF_VSOCK loopback client");
        assert_eq!(peer_cid, LOOPBACK_CID);

        let socket_name = format!("apkrun-vsock-loopback-{}", std::process::id());
        let listener = bind_abstract_listener(&socket_name).expect("bind abstract agent socket");
        let agent = connect_abstract(&socket_name).expect("connect through production helper");
        let mut agent_peer = accept_unix(&listener).expect("accept abstract agent connection");

        set_socket_timeout(&agent_peer, Duration::from_secs(3))
            .expect("set bounded agent peer timeout");

        let bridge_thread = thread::Builder::new()
            .name("vsock-loopback-test-bridge".to_owned())
            .spawn(move || bridge(bridge_vsock, agent))
            .expect("start production copy bridge");

        let exchange_result = (|| -> io::Result<()> {
            let host_message = b"host-to-agent-loopback";
            host_peer.write_all(host_message)?;
            let mut received = vec![0; host_message.len()];
            agent_peer.read_exact(&mut received)?;
            assert_eq!(received, host_message);

            let agent_message = b"agent-to-host-loopback";
            agent_peer.write_all(agent_message)?;
            let mut received = vec![0; agent_message.len()];
            host_peer.read_exact(&mut received)?;
            assert_eq!(received, agent_message);
            Ok(())
        })();

        drop(host_peer);
        let bridge_result = bridge_thread
            .join()
            .expect("production bridge thread must not panic");
        exchange_result.expect("production bridge must copy data in both directions");
        bridge_result.expect("production bidirectional copy should succeed");
    }

    fn set_nonblocking(socket: &impl AsRawFd) -> io::Result<()> {
        // SAFETY: fcntl only reads and updates status flags on this live descriptor.
        let flags = unsafe { libc::fcntl(socket.as_raw_fd(), libc::F_GETFL) };
        if flags < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: fcntl only updates status flags on this live descriptor.
        let result =
            unsafe { libc::fcntl(socket.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) };
        if result < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    fn local_vsock_port(listener: &File) -> io::Result<u32> {
        // SAFETY: zero is a valid initial representation for sockaddr_vm.
        let mut address: libc::sockaddr_vm = unsafe { mem::zeroed() };
        let mut address_len = size_of::<libc::sockaddr_vm>() as libc::socklen_t;
        // SAFETY: listener is live and the address buffer/length are writable and correctly sized.
        let result = unsafe {
            libc::getsockname(
                listener.as_raw_fd(),
                (&mut address as *mut libc::sockaddr_vm).cast(),
                &mut address_len,
            )
        };
        if result < 0 {
            return Err(io::Error::last_os_error());
        }
        if address_len as usize != size_of::<libc::sockaddr_vm>()
            || address.svm_family as libc::c_int != libc::AF_VSOCK
            || address.svm_port == 0
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "AF_VSOCK listener returned an invalid bound address",
            ));
        }
        Ok(address.svm_port)
    }

    fn connect_vsock(cid: u32, port: u32) -> io::Result<File> {
        let stream = socket(libc::AF_VSOCK)?;
        // SAFETY: zero is a valid initial representation for sockaddr_vm.
        let mut address: libc::sockaddr_vm = unsafe { mem::zeroed() };
        address.svm_family = libc::AF_VSOCK as libc::sa_family_t;
        address.svm_cid = cid;
        address.svm_port = port;
        // SAFETY: address is fully initialized and stream is a live AF_VSOCK socket.
        let result = unsafe {
            libc::connect(
                stream.as_raw_fd(),
                (&address as *const libc::sockaddr_vm).cast(),
                size_of::<libc::sockaddr_vm>() as libc::socklen_t,
            )
        };
        if result < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(stream)
    }

    fn bind_abstract_listener(name: &str) -> io::Result<File> {
        let listener = socket(libc::AF_UNIX)?;
        let (address, address_len) = abstract_socket_address(name)?;
        // SAFETY: address is a valid NUL-prefixed abstract Unix socket address.
        let result = unsafe {
            libc::bind(
                listener.as_raw_fd(),
                (&address as *const libc::sockaddr_un).cast(),
                address_len,
            )
        };
        if result < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: listener is a live AF_UNIX socket bound above.
        if unsafe { libc::listen(listener.as_raw_fd(), 1) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(listener)
    }

    fn accept_unix(listener: &File) -> io::Result<File> {
        // SAFETY: listener is live; accept does not require an address buffer.
        let fd = unsafe {
            libc::accept4(
                listener.as_raw_fd(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                libc::SOCK_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: accept4 returned a new descriptor whose ownership transfers to this File.
        Ok(unsafe { File::from_raw_fd(fd) })
    }

    fn abstract_socket_address(name: &str) -> io::Result<(libc::sockaddr_un, libc::socklen_t)> {
        // SAFETY: zero is a valid initial representation for sockaddr_un.
        let mut address: libc::sockaddr_un = unsafe { mem::zeroed() };
        if name.is_empty() || name.len() + 1 > address.sun_path.len() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "abstract socket name is empty or too long",
            ));
        }
        address.sun_family = libc::AF_UNIX as libc::sa_family_t;
        for (index, byte) in name.bytes().enumerate() {
            address.sun_path[index + 1] = byte as libc::c_char;
        }
        let address_len = (size_of::<libc::sa_family_t>() + 1 + name.len()) as libc::socklen_t;
        Ok((address, address_len))
    }

    fn set_socket_timeout(socket: &impl AsRawFd, timeout: Duration) -> io::Result<()> {
        let value = libc::timeval {
            tv_sec: timeout.as_secs() as libc::time_t,
            tv_usec: timeout.subsec_micros() as libc::suseconds_t,
        };
        // SAFETY: value points to a valid timeval and socket is a live descriptor.
        let result = unsafe {
            libc::setsockopt(
                socket.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_RCVTIMEO,
                (&value as *const libc::timeval).cast(),
                size_of::<libc::timeval>() as libc::socklen_t,
            )
        };
        if result < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: value points to a valid timeval and socket is a live descriptor.
        let result = unsafe {
            libc::setsockopt(
                socket.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_SNDTIMEO,
                (&value as *const libc::timeval).cast(),
                size_of::<libc::timeval>() as libc::socklen_t,
            )
        };
        if result < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
}
