#if __has_include(<FlutterMacOS/FlutterMacOS.h>)
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif
@interface Gpu3dPlugin : NSObject <FlutterPlugin>
@end
