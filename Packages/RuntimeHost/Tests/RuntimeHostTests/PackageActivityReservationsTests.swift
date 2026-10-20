import Testing

@testable import RuntimeHost

@Test
func packageReservationsSerializeMutationsWithLaunches() throws {
    var reservations = PackageActivityReservations()
    let packageID = "io.apkrun.fixture.hellotext"

    try reservations.beginLaunch(packageID: packageID)
    try reservations.beginUninstall(packageID: packageID)

    #expect(reservations.hasActiveLaunches(packageID: packageID))
    #expect(
        throws: PackageActivityReservations.Failure.uninstallInProgress
    ) {
        try reservations.beginLaunch(packageID: packageID)
    }

    reservations.finishLaunch(packageID: packageID)
    #expect(!reservations.hasActiveLaunches(packageID: packageID))
    #expect(reservations.isUninstalling(packageID: packageID))

    reservations.finishUninstall(packageID: packageID)
    try reservations.beginLaunch(packageID: packageID)
    reservations.finishLaunch(packageID: packageID)

    try reservations.beginLaunch(packageID: packageID)
    try reservations.beginInstall(packageID: packageID)
    #expect(reservations.hasActiveLaunches(packageID: packageID))
    #expect(
        throws: PackageActivityReservations.Failure.installInProgress
    ) {
        try reservations.beginUninstall(packageID: packageID)
    }
    #expect(
        throws: PackageActivityReservations.Failure.installInProgress
    ) {
        try reservations.beginLaunch(packageID: packageID)
    }
    try reservations.beginLaunch(packageID: "io.apkrun.fixture.hellocompose")
    reservations.finishLaunch(packageID: "io.apkrun.fixture.hellocompose")
    reservations.finishLaunch(packageID: packageID)
    #expect(!reservations.hasActiveLaunches(packageID: packageID))

    reservations.finishInstall(packageID: packageID)
    try reservations.beginForget(packageID: packageID)
    #expect(
        throws: PackageActivityReservations.Failure.forgetInProgress
    ) {
        try reservations.beginInstall(packageID: packageID)
    }
    #expect(
        throws: PackageActivityReservations.Failure.forgetInProgress
    ) {
        try reservations.beginUninstall(packageID: packageID)
    }
    try reservations.beginLaunch(packageID: packageID)
    reservations.finishLaunch(packageID: packageID)
    reservations.finishForget(packageID: packageID)
}
