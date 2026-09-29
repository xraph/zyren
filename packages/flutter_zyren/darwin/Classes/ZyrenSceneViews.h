#import "ZyrenPlugin.h"

@interface ZyrenSceneViews : NSObject <FlutterPlatformViewFactory>
- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar
                         connect:(void *(^)(uint64_t))connect;
- (void)closeAll;
@end
