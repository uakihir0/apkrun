//! Small, static bridge between host-initiated vsock channels and guest agent sockets.

use std::io;

#[cfg(any(target_os = "android", target_os = "linux", test))]
use std::{sync::atomic::AtomicUsize, sync::Arc};

/// The only CID permitted to connect to the guest bridge.
pub const HOST_VSOCK_CID: u32 = 2;
/// Maximum active bridge connections for an individual vsock port.
pub const MAX_CONNECTIONS_PER_PORT: usize = 8;
/// Maximum bytes copied at once in each direction.
pub const COPY_BUFFER_BYTES: usize = 64 * 1024;

/// A fixed port-to-agent mapping. Socket names are Linux abstract names without the leading `@`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PortMapping {
    /// Host-facing vsock port.
    pub port: u32,
    /// Agent-owned Linux abstract socket name.
    pub abstract_socket: &'static str,
}

/// Fixed channel mapping; ports cannot be redirected by runtime configuration.
pub const PORT_MAPPINGS: [PortMapping; 5] = [
    PortMapping {
        port: 6100,
        abstract_socket: "apkrun-guestd-control",
    },
    PortMapping {
        port: 6101,
        abstract_socket: "apkrun-guestd-input",
    },
    PortMapping {
        port: 6102,
        abstract_socket: "apkrun-guestd-bulk",
    },
    PortMapping {
        port: 6110,
        abstract_socket: "apkrun-store-control",
    },
    PortMapping {
        port: 6111,
        abstract_socket: "apkrun-store-artifacts",
    },
];

#[cfg(any(target_os = "android", target_os = "linux", test))]
#[derive(Clone, Debug)]
struct ConnectionLimiter {
    active: Arc<AtomicUsize>,
    maximum: usize,
    port: u32,
}

#[cfg(any(target_os = "android", target_os = "linux", test))]
impl ConnectionLimiter {
    fn new(maximum: usize, port: u32) -> Self {
        Self {
            active: Arc::new(AtomicUsize::new(0)),
            maximum,
            port,
        }
    }

    fn try_acquire(&self) -> Option<ConnectionPermit> {
        self.active
            .fetch_update(
                std::sync::atomic::Ordering::AcqRel,
                std::sync::atomic::Ordering::Acquire,
                |active| (active < self.maximum).then_some(active + 1),
            )
            .ok()
            .map(|_| ConnectionPermit {
                active: Arc::clone(&self.active),
                port: self.port,
            })
    }
}

#[cfg(any(target_os = "android", target_os = "linux", test))]
#[derive(Debug)]
struct ConnectionPermit {
    active: Arc<AtomicUsize>,
    port: u32,
}

#[cfg(any(target_os = "android", target_os = "linux", test))]
impl Drop for ConnectionPermit {
    fn drop(&mut self) {
        let previous = self
            .active
            .fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
        debug_assert!(previous > 0, "connection permit must be released once");
        log::info!(
            "bridge released on port {} (active {})",
            self.port,
            previous - 1
        );
    }
}

/// Starts one listener for each fixed guest agent channel.
pub fn run() -> io::Result<()> {
    #[cfg(any(target_os = "android", target_os = "linux"))]
    {
        linux::run()
    }

    #[cfg(not(any(target_os = "android", target_os = "linux")))]
    {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "apkrun_vsockd requires Linux or Android",
        ))
    }
}

#[cfg(any(target_os = "android", target_os = "linux"))]
mod linux;

#[cfg(test)]
mod tests {
    use super::{
        ConnectionLimiter, COPY_BUFFER_BYTES, HOST_VSOCK_CID, MAX_CONNECTIONS_PER_PORT,
        PORT_MAPPINGS,
    };

    #[test]
    fn maps_only_the_documented_guest_and_store_channels() {
        assert_eq!(
            PORT_MAPPINGS.map(|mapping| (mapping.port, mapping.abstract_socket)),
            [
                (6100, "apkrun-guestd-control"),
                (6101, "apkrun-guestd-input"),
                (6102, "apkrun-guestd-bulk"),
                (6110, "apkrun-store-control"),
                (6111, "apkrun-store-artifacts"),
            ]
        );
        assert!(PORT_MAPPINGS
            .windows(2)
            .all(|pair| pair[0].port != pair[1].port));
        assert_eq!(HOST_VSOCK_CID, 2);
        assert_eq!(COPY_BUFFER_BYTES, 64 * 1024);
    }

    #[test]
    fn enforces_eight_active_connections_per_port_and_releases_slots() {
        let limiter = ConnectionLimiter::new(MAX_CONNECTIONS_PER_PORT, 6100);
        let mut permits = (0..MAX_CONNECTIONS_PER_PORT)
            .map(|_| limiter.try_acquire().expect("slot should be available"))
            .collect::<Vec<_>>();

        assert!(limiter.try_acquire().is_none());
        drop(permits.pop());
        let replacement = limiter
            .try_acquire()
            .expect("released slot should be reusable");
        assert!(limiter.try_acquire().is_none());
        drop(replacement);
        drop(permits);
        assert!(limiter.try_acquire().is_some());
    }
}
