# SOS Program Manage

SOS Program Manage is a small Cadence Virtuoso integration for managing SOS
membership files and refreshing per-user CDS workspaces from a Virtuoso menu.

The default deployment layout matches the shared Virtuoso server convention:
SKILL files live under `skill/`, and shell backends live under `shell/`.

## Features

- Adds a `SOS Program Manage` menu to CIW, schematic, and maskLayout windows.
- Provides `SOS Administration...` for user and group administration.
- Provides `Refresh Workspace` as a top-level menu action.
- Updates `sosd.cfg` group membership and the wafer `user_list`.
- Runs `sosadmin readcfg` after changes when a server name is available.
- Synchronizes workspace directories from `user_list` through `workspace_admin.sh`.

## Repository Layout

```text
.
|-- sos_init.il              # Virtuoso entry point and menu registration
|-- sos_utils.il             # Shared SKILL path/config/log helpers
|-- sos_runner.il            # SKILL-to-shell async runner
|-- gui_add_people.il        # SOS Administration form and callbacks
|-- sos_admin.sh             # Membership/group management backend
|-- workspace_admin.sh       # Workspace create/remove/refresh backend
|-- sos_admin.conf.example   # Optional config template
|-- .gitattributes
|-- .gitignore
`-- README.md
```

Local `AGENTS*.md`, `doc/`, and `bak/` files are intentionally ignored and are
not part of the GitHub distribution.

## Server Layout

Default install location:

```text
/CAD_Tools/scripts
|-- shell
|   |-- sos_admin.sh
|   `-- workspace_admin.sh
`-- skill
    |-- sos_init.il
    |-- sos_utils.il
    |-- sos_runner.il
    `-- gui_add_people.il
```

The repository is stored flat for GitHub, but deployment should place `.il`
files in `skill/` and `.sh` files in `shell/` unless you intentionally change
the paths in `sos_init.il`.

## Install

1. Copy files to the Virtuoso-side install directory:

   ```bash
   cp *.il /CAD_Tools/scripts/skill/
   cp *.sh /CAD_Tools/scripts/shell/
   ```

2. In `sos_init.il`, set:

   ```skill
   setq( sos_gToolRoot "/CAD_Tools/scripts" )
   ```

   The default derived paths are:

   ```skill
   setq( sos_gSkillDir strcat(sos_gToolRoot "/skill") )
   setq( sos_gShellDir strcat(sos_gToolRoot "/shell") )
   ```

   If another site deploys everything in one flat directory, change both derived
   paths to `sos_gToolRoot`.

3. Load the tool from CIW:

   ```skill
   load("/CAD_Tools/scripts/skill/sos_init.il")
   ```

   Or add the same `load(...)` call to your `.cdsinit`.

## Expected Project Layout

The scripts assume wafers live under:

```text
/project/Design_Data/<wafer>
```

Expected files and directories include:

```text
/project/Design_Data/<wafer>/config/user_config/sos_admin.conf
/project/Design_Data/<wafer>/config/user_config/user_list
/project/Design_Data/<wafer>/config/eda_config/module_temp.cshrc
/project/Design_Data/<wafer>/work_libs/user_temp
/project/Design_Data/<wafer>/work_libs/<user>/workspace/CDS_workspace
```

`sos_admin.sh` can also discover `sosd.cfg` from common SOS replica paths such
as:

```text
/sos_data/*.rep/<wafer>/setup/sosd.cfg
```

## Configuration

Copy the example config to the wafer user config directory:

```bash
cp sos_admin.conf.example /project/Design_Data/<wafer>/config/user_config/sos_admin.conf
```

Then set values as needed:

```text
SOS_SERVER_NAME=
SOS_CFG=
SOS_USER_LIST=
```

`SOS_SERVER_NAME` is used by `sosadmin readcfg`. `SOS_CFG` and `SOS_USER_LIST`
are optional overrides when automatic discovery is not sufficient.

## Virtuoso Menu

After loading `sos_init.il`, the `SOS Program Manage` menu contains:

- `SOS Administration...`
- `Refresh Workspace`
- `Reload SOS Tools`

`SOS Administration...` opens a form with user/group operations. The `Wafer Root`
and `SOS Server` fields are read-only and are detected from the current
Virtuoso working directory and wafer config.

`Refresh Workspace` directly runs `workspace_admin.sh` for the current wafer.

## Backend Commands

### Membership Administration

```bash
bash sos_admin.sh add-group design_phy
bash sos_admin.sh remove-group design_phy
bash sos_admin.sh add design_analog alice bob
bash sos_admin.sh remove design_analog alice
bash sos_admin.sh groups alice
bash sos_admin.sh users design_analog
bash sos_admin.sh list-groups
```

Useful options:

```bash
bash sos_admin.sh --dry-run add design_analog alice
bash sos_admin.sh --no-readcfg add design_analog alice
bash sos_admin.sh --cfg /path/to/sosd.cfg --user-list /path/to/user_list list-groups
```

### Workspace Refresh

```bash
bash workspace_admin.sh
bash workspace_admin.sh --log
```

`workspace_admin.sh` compares the wafer `user_list` with existing
`work_libs/<user>` directories:

- creates missing workspaces from `work_libs/user_temp`
- removes workspace directories for users no longer listed
- runs SOS workarea commands as each target user

## Safety Notes

- `sos_admin.sh` creates timestamped backups beside `sosd.cfg` before edits.
- `workspace_admin.sh` requires `sudo`, `tcsh`, and `soscmd` for workspace
  operations.
- Numeric user names are rejected to avoid UID/name ambiguity.
- The protected template workspace name is `user_temp`.
- Workspace removal is constrained to direct children of the wafer `work_libs`
  directory.

## Validation

Before publishing changes, run:

```bash
bash -n sos_admin.sh
bash -n workspace_admin.sh
```

If available, also run:

```bash
shellcheck sos_admin.sh workspace_admin.sh
```

For SKILL changes, load `sos_init.il` in a non-production Virtuoso session and
verify that the menu entries appear and callbacks execute as expected.
