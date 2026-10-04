# Fresh checkout checks

The receipt pins the detached source commit and the complete output of four
checks. Offline dependency resolution, source analysis, accepted-model integrity
and seven benchmark regressions passed in a new managed checkout.

The checkout reused the workstation's installed SDK and dependency cache. No
native build or device run was performed there. Dependency resolution generated
host configuration changes listed in the receipt, including the Game Lab iOS
Podfile and CocoaPods includes. This is partial setup evidence, not a release
qualification.
