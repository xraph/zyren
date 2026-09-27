#import "Gpu3dPlugin.h"

// Experimental native presentation fixture. No public Dart facade depends on it.
@interface Gpu3dMetalViews : NSObject <FlutterPlatformViewFactory>
- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar
                         connect:(void *(^)(uint64_t))connect;
- (void)closeAll;
@end
