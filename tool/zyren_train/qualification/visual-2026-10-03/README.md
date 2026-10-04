# Visual acceptance plans

You can inspect the frozen plans in `plans/`. Each mode uses the existing guard and vehicle quality targets, 200 episodes per family, actual native stress scenarios, a 240-step paired hidden-world check and the reward exploit suite. RGB, depth and combined observations have separate plans and exact shared profile hashes.

These are plans, not passing model receipts. No accepted visual model is included.

Final guard seeds start at 20001, vehicle seeds at 30001, and the paired worlds use 25001. Development pilot seeds 1001 through 1005 are excluded. Training seeds and recording sources cannot enter the held-out partitions.

`native-schemas.json` and `native-scenarios.json` were read from the actual frozen worker before these plans were locked. The worker SHA is `cc102a7b7625e89f7ee9e3805b3f722777ad43a003103514bc103d0afb536706`; every copied native library is pinned in each plan. Keep that executable and its libraries when you reproduce an evaluation. Rebuilding another executable does not satisfy these pins.

The course assets, procedural textures and scenario code are repository-authored. No downloaded model weights or external training inputs are included.
