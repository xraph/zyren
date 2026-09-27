#import "Gpu3dPlugin.h"

@interface Gpu3dSceneViews : NSObject <FlutterPlatformViewFactory>
- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar
                         connect:(void *(^)(uint64_t))connect;
- (void)closeAll;
@end
