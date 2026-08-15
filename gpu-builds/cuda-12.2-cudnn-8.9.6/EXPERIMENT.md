1. Confirm the old SIF has the bug
  apptainer exec /scout/containers/folding_260515.2.sif bash -c \
    'cat /.singularity.d/env/90-environment.sh | sed -n "20,30p"; which p3x-app-shepherd'
  Should show the empty if/then/fi blocks and produce the same error.

  2. Get apptainer 1.4.5 alongside current 1.5.0
  Easiest path: download the static binary from GitHub releases — no install needed, just unpack to a temp dir.
  curl -L -o /tmp/apptainer-1.4.5.tar.gz \
    https://github.com/apptainer/apptainer/releases/download/v1.4.5/apptainer-1.4.5-1.x86_64.rpm
  # or the .deb / static tarball

  3. Run the same exec with each binary against folding_260515.2.sif
  /tmp/apptainer-1.4.5/bin/apptainer exec /scout/containers/folding_260515.2.sif \
    bash -c 'which p3x-app-shepherd 2>&1; echo "exit=$?"'

  apptainer exec /scout/containers/folding_260515.2.sif \
    bash -c 'which p3x-app-shepherd 2>&1; echo "exit=$?"'

  4. Compare:
  - If 1.4.5 succeeds and 1.5.0 fails → apptainer change is the trigger
  - If both fail identically → bug was always fatal; something else changed (Slurm node config, container runtime, etc.)
  - If 1.4.5 prints a warning but succeeds → confirms shell tolerance changed between versions

  Bonus — strace to see which shell is invoked:
  strace -f -e execve apptainer exec ... 2>&1 | grep -i 'sh\|env'
  Reveals if 1.5.0 actually picks a different /bin/sh (which is where the LD_LIBRARY_PATH precedence change in 1.5.0 might matter).
