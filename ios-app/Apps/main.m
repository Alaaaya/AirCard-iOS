// main.m — AirCard entry point.
//
// Gives the Container loader a chance to run a guest app before SwiftUI
// starts; otherwise hands over to the SwiftUI app (AirCardApp).
#import <Foundation/Foundation.h>

extern int AirCardGuestLaunchIfRequested(int argc, char *argv[]);
extern void aircard_swift_main(void);

int main(int argc, char *argv[]) {
    AirCardGuestLaunchIfRequested(argc, argv); // returns only when nothing to launch / failed
    aircard_swift_main();
    return 0;
}
