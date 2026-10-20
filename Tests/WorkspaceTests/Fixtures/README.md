`v1/` was generated using the original `FileCheckpointStore` from commit
`cad29c479e28ce905d4e10cf3675c59838c77928`, before changing the storage format.
It contains two checkpoints of `/note`, `/nested/deep/file`, and a relative symlink
`/link -> nested/deep/file`, an append-only mutation log, and the
`mutations.sequence.json` high-water-mark/retraction-epoch sidecar. The first
checkpoint is labeled `legacy`; the second is unlabeled. The bytes are copied
verbatim so compatibility tests exercise persisted data from the old writer.
