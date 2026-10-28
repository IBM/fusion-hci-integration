# Configuration Templates

This directory contains template files for setting up your workspace.

## Quick Start

1. **Create workspace directory** (if it doesn't exist):
   ```bash
   mkdir -p workspace
   ```

2. **Copy the example inventory to workspace**:
   ```bash
   cp templates/integration-setup.example.yaml workspace/integration-setup.yaml
   ```

3. **Customize your configuration**:
   ```bash
   vi workspace/integration-setup.yaml
   ```

4. **Generate the artifacts** (`setup_env.sh`, initial `WorkerPool` CR, MachineConfigs, DNS zone files):
   ```bash
   ./generate-setup workspace/integration-setup.yaml
   ```

5. **Source environment** (in every shell session):
   ```bash
   source setup_env.sh
   ```

## Files

- **integration-setup.example.yaml** - Example inventory; copy to `workspace/integration-setup.yaml`
- **workerpool.yaml.j2** - Template used by `generate-setup` to render the initial `WorkerPool` CR

`setup_env.sh` is not a template: `generate-setup` writes it to the repo root (git-ignored).

## Usage in Documentation

Once you've sourced `setup_env.sh`, all documentation examples using `${VARIABLES}` will work with your configuration.

## Multiple Environments

You can maintain multiple workspace directories for different environments:

```bash
workspace-dev/
workspace-test/
workspace-prod/
```

Run `generate-setup` against the inventory of each environment and source the resulting `setup_env.sh`.