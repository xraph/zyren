# Game Lab iOS build

You can build the native game host for iOS after running `fvm flutter pub get`
from `examples/game_lab`. This creates the local Swift package before Xcode
resolves it. Flutter installs the two existing CocoaPods plugins during the
build; the app now retains their project integration and dependency lock.

The unsigned arm64 release build passed on 2026-10-03. Its complete 52,061,924-byte
application inventory and build log are pinned in `receipt.json`. Source changed
during the build, so this receipt cannot establish an exact-source release.
There was no physical iPhone or iPad run. Signing and device qualification remain
open, along with the sustained game performance gates.
