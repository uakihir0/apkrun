import Foundation
import Testing

@testable import RuntimeCore

/// The readers of the adb replies (#016 T0). The replies are recorded from a real Android 17 guest on 2026-10-09:
/// `adb install -r`, `adb uninstall`, `pm list packages --show-versioncode`, and `dumpsys package`.
@Test
func installReplyOfASuccessfulInstallIsSuccess() {
    #expect(AdbOutputParser.packageReply("Performing Streamed Install\nSuccess\n") == .success)
}

@Test
func installRejectionCarriesAndroidsReasonCode() {
    // adb prints a rejection on standard error, after its own prefix.
    let reply = "adb: failed to install /tmp/HelloText.apk: Failure [INSTALL_FAILED_VERSION_DOWNGRADE]"
    #expect(AdbOutputParser.packageReply(reply) == .failure(reason: "INSTALL_FAILED_VERSION_DOWNGRADE"))
}

@Test
func uninstallOfAMissingPackageIsAFailureWithItsCode() {
    // The recorded reply of a second `adb uninstall`.
    #expect(
        AdbOutputParser.packageReply("Failure [DELETE_FAILED_INTERNAL_ERROR]\n")
            == .failure(reason: "DELETE_FAILED_INTERNAL_ERROR")
    )
}

@Test
func anEmptyOrUnrecognizedReplyIsUnknown() {
    #expect(AdbOutputParser.packageReply("") == .unknown)
    #expect(AdbOutputParser.packageReply("Performing Streamed Install\n") == .unknown)
    #expect(AdbOutputParser.packageReply("Failure []") == .failure(reason: "unknown"))
}

@Test
func packageListingReadsNamesAndVersionCodes() {
    // The recorded reply of `pm list packages --show-versioncode io.apkrun.fixture.hellotext`.
    let listing = AdbOutputParser.packageListings("package:io.apkrun.fixture.hellotext versionCode:1\n")
    #expect(listing == [AdbPackageListing(name: "io.apkrun.fixture.hellotext", versionCode: 1)])
}

@Test
func packageListingOfNothingIsEmptyAndAMissingVersionCodeIsNil() {
    #expect(AdbOutputParser.packageListings("").isEmpty)
    #expect(
        AdbOutputParser.packageListings("package:com.example.app\n")
            == [AdbPackageListing(name: "com.example.app", versionCode: nil)]
    )
}

@Test
func dumpsysMetadataOfTheInstalledFixtureMatchesTheManifest() {
    // The block is recorded from `dumpsys package io.apkrun.fixture.hellotext` after `adb install -r`.
    let metadata = AdbOutputParser.packageMetadata(recordedDumpsys, packageName: "io.apkrun.fixture.hellotext")
    #expect(
        metadata
            == AdbPackageMetadata(versionCode: 1, versionName: "1.0", minSdk: 29, targetSdk: 37)
    )
}

@Test
func dumpsysOfAnotherPackageIsNotReadAsThisOne() {
    #expect(AdbOutputParser.packageMetadata(recordedDumpsys, packageName: "io.apkrun.other") == nil)
}

@Test
func dumpsysWithoutAVersionCodeIsNil() {
    let text = "Package [io.apkrun.fixture.hellotext] (abc):\n    versionName=1.0\n"
    #expect(AdbOutputParser.packageMetadata(text, packageName: "io.apkrun.fixture.hellotext") == nil)
}

/// `dumpsys package io.apkrun.fixture.hellotext`, from the first line of the package block to its signatures.
private let recordedDumpsys = """
      Package [io.apkrun.fixture.hellotext] (e3e9947):
        appId=10122
        pccId=-1
        pkg=Package{2c52988 io.apkrun.fixture.hellotext}
        codePath=/data/app/~~n2bh9d3uwcIzWkLTn8026g==/io.apkrun.fixture.hellotext-gHuXLrpyNbgiI-EumUx7rw==
        resourcePath=/data/app/~~n2bh9d3uwcIzWkLTn8026g==/io.apkrun.fixture.hellotext-gHuXLrpyNbgiI-EumUx7rw==
        legacyNativeLibraryDir=/data/app/~~n2bh9d3uwcIzWkLTn8026g==/io.apkrun.fixture.hellotext-gHuXLrpyNbgiI-EumUx7rw==/lib
        extractNativeLibs=false
        primaryCpuAbi=null
        secondaryCpuAbi=null
        cpuAbiOverride=null
        versionCode=1 minSdk=29 targetSdk=37
        minExtensionVersions=[]
        versionName=1.0
        hiddenApiEnforcementPolicy=2
        usesNonSdkApi=false
        splits=[base]
        apkSigningVersion=2
        flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]
        privateFlags=[ PRIVATE_FLAG_ACTIVITIES_RESIZE_MODE_RESIZEABLE_VIA_SDK_VERSION ALLOW_AUDIO_PLAYBACK_CAPTURE PRIVATE_FLAG_ALLOW_NATIVE_HEAP_POINTER_TAGGING ]
        forceQueryable=false
        pageSizeCompat=0
        scannedAsStoppedSystemApp=false
        supportsScreens=[small, medium, large, xlarge, resizeable, anyDensity]
        timeStamp=2026-10-09 06:11:38
        lastUpdateTime=2026-10-09 06:11:38
        installerPackageName=null
        installerPackageUid=-1
        initiatingPackageName=com.android.shell
        originatingPackageName=null
        packageSource=1
        appMetadataFilePath=null
        appMetadataSource=0
        signatures=PackageSignatures{7ca4f21 version:2, signatures:[1cbf3ab3], past signatures:[]}
    """
