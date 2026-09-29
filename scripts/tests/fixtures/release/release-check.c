#ifndef RELEASE_CHECK_MARKER
#define RELEASE_CHECK_MARKER "APKRUN_RELEASE_FIXTURE_CLEAN"
#endif

static const char fixtureMarker[] = RELEASE_CHECK_MARKER;

int main(void) {
    volatile unsigned char firstByte = fixtureMarker[0];
    return firstByte == 0;
}
