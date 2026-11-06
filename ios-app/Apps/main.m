// main.m — AirCard entry point.
//
// Gives the Container loader a chance to run a guest app before SwiftUI
// starts; otherwise hands over to the SwiftUI app (AirCardApp).
#import <Foundation/Foundation.h>

extern int MirsaGuestLaunchIfRequested(int argc, char *argv[]);
extern void mirsa_swift_main(void);

int main(int argc, char *argv[]) {
    MirsaGuestLaunchIfRequested(argc, argv); // returns only when nothing to launch / failed
    mirsa_swift_main();
    return 0;
}
