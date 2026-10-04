# Failed depth development pilots

You can inspect the two failed checkpoints and their hash-chained training receipts here. Neither model is accepted. All development seeds are 1001 through 1005, outside the locked final test set.

The imbalanced run used four successful native TRAIN teacher courses, 15 cloning epochs and 64 PPO steps. It failed all five development courses. Its moveX and moveZ accuracy on 3,000 native teacher-driven validation steps was 36.33% and 46.00%; the other four heads were constant and correct. Mirroring the actual depth image or replacing body values with TRAIN means changed neither predictions nor trajectories.

The balanced run used seven successful TRAIN courses, 60 cloning epochs and 64 PPO steps. Cloning loss fell from 5.6190 to 0.3472. Expert-path accuracy reached 93.40% for moveX and 92.27% for moveZ, but closed-loop success remained zero out of five. Mirrored images reduced moveX accuracy to 32.30%; body means reduced moveZ accuracy to 72.70%. Both ablations caused contacts on all five courses, compared with zero contacts for the original student. Camera and body dependence improved. Task quality did not pass.

The balanced trainer measured 352.90 seconds wall time and 342.05 seconds process CPU time. These are concurrent development measurements, not qualified throughput. Its bounded source cache held at most 256 MiB and was checked against recording hashes each epoch.

`config.json` retains the exact original canonical bytes, including local dataset paths, so its SHA still matches each checkpoint. The recording manifests and metadata pin the compressed camera chunks, which remain in the local pilot directories under `.superpowers/sdd/README/`; those chunks are not duplicated here. The checkpoints, finalized receipts, validation predictions and outcome records are durable. The first run used the frozen `53af587b8f98` worker. Validation imitation diagnostics used the later `cc102a7b7625` worker with the same shared camera and action schemas. Each diagnostic records its own worker pin where applicable.

You must not use these development receipts as ONNX qualification, final held-out evaluation or evidence of visual task acceptance. Teacher labels stayed outside actor inputs and normalization.
