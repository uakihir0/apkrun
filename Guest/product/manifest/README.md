# Pinned AOSP manifest

`pinned.xml` is the `repo manifest -r` snapshot the release build syncs
to (android-image.md §11.1, build-system.md §9). It records the exact
project revisions of the `trunk_staging` tree a release image is built
from, so the same revision produces the same tree.

It is generated on the Linux builder (environment-setup.md §5), where
`repo` and the AOSP checkout exist:

```bash
scripts/aosp/build-product.sh --pin-manifest          # writes pinned.xml
```

Commit the regenerated file together with the commit it pins. A build
run syncs to the committed `pinned.xml`; `--update-manifest` syncs to
the tree's current revisions and rewrites the file instead.
