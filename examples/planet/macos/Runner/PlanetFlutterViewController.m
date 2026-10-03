#import "PlanetFlutterViewController.h"
#import "PlanetSemanticsRoot.h"

// Flutter 3.47.5's macOS bridge can receive a queued partial update after its
// accessibility tree has been recreated. If that update becomes the root,
// CreateRemoveReparentedNodesUpdate later dereferences a missing parent.
// Keep this compatibility hook in the example runner, not in the renderer.
// These selectors are internal Flutter methods; requalify on SDK upgrades.
@interface FlutterViewController (PlanetSemanticsCompatibility)
- (void)notifySemanticsEnabledChanged;
- (void)updateSemantics:(const void *)update;
@end

@implementation PlanetFlutterViewController {
  BOOL _receivedSemanticsRoot;
}

- (void)notifySemanticsEnabledChanged {
  _receivedSemanticsRoot = NO;
  [super notifySemanticsEnabledChanged];
}

- (void)updateSemantics:(const void *)update {
  if (!_receivedSemanticsRoot) {
    if (!PlanetSemanticsHasRoot(update)) return;
    _receivedSemanticsRoot = YES;
  }
  [super updateSemantics:update];
}

@end
