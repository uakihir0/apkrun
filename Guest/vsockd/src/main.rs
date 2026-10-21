fn main() {
    #[cfg(target_os = "android")]
    android_logger::init_once(
        android_logger::Config::default()
            .with_tag("apkrun_vsockd")
            .with_max_level(log::LevelFilter::Info),
    );

    if let Err(error) = apkrun_vsockd::run() {
        log::error!("bridge stopped: {error}");
        std::process::exit(1);
    }
}
