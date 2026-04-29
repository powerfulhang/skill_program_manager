;;; =============================================================================
;;; gui_add_people.il - SOS Administration GUI
;;;
;;; Provides a modeless form with two administration modes:
;;; - User Admin - add/remove users and list groups for a user
;;; - Group Admin - add/remove groups, list users, and list all groups
;;;
;;; Plus a workspace sync button that calls workspace_admin.sh.
;;; All shell output is streamed to CIW via sos_runner.il callbacks.
;;;
;;; Entry point: gui_addPeople() - loaded by sos_init.il - sos_loadModules().
;;; =============================================================================


;;; -----------------------------------------------------------------------------
;;; 1. Internal helpers
;;; -----------------------------------------------------------------------------
;;; Read a string field value from the main form by field name.
;;; Returns "" if the field or value is nil.
procedure( sos_guiGetField(form fieldSym)
  ;; Ref: Cadence User Interface SKILL Functions Reference - Forms:
  ;; form fields are referenced as formHandle->fieldSym; Cadence Community
  ;; AE guidance uses get(form fieldSym) for dynamic field symbols.
  get(form fieldSym)
)

procedure( sos_guiGetString(form fieldSym)
  let( (fh val)
    fh  = sos_guiGetField(form fieldSym)
    val = if(fh then fh->value else "")
    if(val then val else "")
  )
)

;;; Read a boolean field value from the main form by field name.
procedure( sos_guiGetBool(form fieldSym)
  let( (fh)
    fh = sos_guiGetField(form fieldSym)
    if(fh then fh->value else nil)
  )
)

;;; Set a field value on the main form by field name.
procedure( sos_guiSetValue(form fieldSym value)
  let( (fh)
    fh = sos_guiGetField(form fieldSym)
    when(fh
      fh->value = value
    )
    value
  )
)

;;; Show validation errors in a modal Close-only dialog instead of CIW.
procedure( sos_guiAlert(msg)
  ;; Ref: Cadence User Interface SKILL Functions Reference - hiDisplayAppDBox.
  hiDisplayAppDBox(
    ?name        'sosAdminInputAlert
    ?dboxBanner  "SOS Administration"
    ?dboxText    msg
    ?dialogStyle 'modal
    ?buttonLayout 'Close
  )
  nil
)

;;; Quote one shell argument.  Single quotes are rejected instead of guessed,
;;; because these commands eventually mutate project membership files.
procedure( sos_shellQuoteArg(label value)
  let( (text)
    text = if(value then value else "")
    if( rexMatchp("'" text) then
      sos_guiAlert(strcat(label " must not contain a single quote: " text))
      nil
    else
      strcat("'" text "'")
    )
  )
)

;;; Quote a whitespace-separated list of shell arguments.
procedure( sos_shellQuoteTokenList(label text)
  let( (tokens result quoted ok)
    tokens = parseString(if(text then text else "") " \t\n")
    result = ""
    ok = t
    foreach( token tokens
      when( ok && token != ""
        quoted = sos_shellQuoteArg(label token)
        if( quoted then
          result = strcat(result (if result == "" then "" else " ") quoted)
        else
          ok = nil
        )
      )
    )
    if(ok && result != "" then result else nil)
  )
)

;;; Reject pure numeric user tokens before shell dispatch.  Numeric strings can
;;; be resolved as UIDs by getent/id on Linux, but this GUI expects login names.
procedure( sos_guiRejectNumericUsers(label text)
  let( (tokens bad)
    tokens = parseString(if(text then text else "") " \t\n")
    bad = nil
    foreach( token tokens
      when( token != "" && rexMatchp("^[0-9]+$" token)
        bad = token
      )
    )
    if( bad then
      sos_guiAlert(strcat(label " must contain login names, not numeric UIDs: " bad))
      nil
    else
      t
    )
  )
)

;;; Build an optional sos_admin.sh --server argument.
procedure( sos_guiServerOpt(server)
  let( (quoted)
    if( server == "" then
      ""
    else
      quoted = sos_shellQuoteArg("SOS Server" server)
      if(quoted then strcat("--server " quoted) else nil)
    )
  )
)

;;; Dispatch a shell command immediately, or return it to a caller that is
;;; composing a larger ordered command sequence.
procedure( sos_guiDispatchShell(cmd)
  if( boundp('sos_gDeferShellRun) && sos_gDeferShellRun then
    cmd
  else
    sos_runShell(cmd)
    cmd
  )
)

procedure( sos_guiDeferShellStart()
  sos_gDeferShellRun = t
  t
)

procedure( sos_guiDeferShellStop()
  sos_gDeferShellRun = nil
  t
)

procedure( sos_guiVisualClearCIW()
  let( (i)
    ;; Ref: Cadence Community, "clearing CIW window?": CIW has no public
    ;; clear-output SKILL command; printing blank lines is the supported
    ;; workaround for visually separating a new operation from old output.
    i = 0
    while( i < 45
      printf("\n")
      i = i + 1
    )
  )
  t
)

procedure( sos_guiQueryHeader(title)
  let( (titleArg)
    titleArg = sos_shellQuoteArg("Query title" title)
    if(titleArg then
      sprintf(nil "printf '\\n===== %%s =====\\n' %s" titleArg)
    else
      nil
    )
  )
)

;;; Pick the current shell login user for paths under work_libs/<user>.
procedure( sos_guiCurrentShellUser()
  let( (user)
    ;; Ref: doc/sklangref_01.pdf - Environment Functions: getShellEnvVar,
    ;; wrapped by sos_getEnv in sos_utils.il.
    user = sos_getEnv("USER")
    when( user == ""
      user = sos_getEnv("LOGNAME")
    )
    user
  )
)

;;; Derive sosd.cfg path from the wafer root field.
procedure( sos_guiDeriveCfg(form)
  let( (waferRoot)
    waferRoot = sos_guiGetString(form 'waferRootField)
    if( waferRoot != "" then strcat(waferRoot "/config/sos_config/sosd.cfg") else "" )
  )
)

;;; Derive user_list path from the wafer root field.
procedure( sos_guiDeriveUserList(form)
  let( (waferRoot)
    waferRoot = sos_guiGetString(form 'waferRootField)
    if( waferRoot != "" then strcat(waferRoot "/config/user_config/user_list") else "" )
  )
)


;;; -----------------------------------------------------------------------------
;;; 2. Wafer path display
;;; -----------------------------------------------------------------------------
;;; Update the read-only string fields to show derived sosd.cfg / user_list paths.
procedure( sos_guiRefreshPaths(form)
  let( (waferRoot cfg userList)
    waferRoot = sos_guiGetString(form 'waferRootField)
    if( waferRoot != "" then
      cfg      = strcat(waferRoot "/config/sos_config/sosd.cfg")
      userList = strcat(waferRoot "/config/user_config/user_list")
    else
      cfg      = "(cannot resolve)"
      userList = "(cannot resolve)"
    )
    sos_guiSetValue(form 'cfgLabel cfg)
    sos_guiSetValue(form 'userListLabel userList)
  )
)

;;; [Detect] button next to Wafer Root - auto-fill from CWD.
procedure( sos_guiDetectWaferRootCB(form)
  let( (detected server)
    detected = sos_detectWaferRoot()
    if( detected != "" then
      sos_guiSetValue(form 'waferRootField detected)
      sos_ok(strcat("Detected wafer root: " detected))
      sos_guiRefreshPaths(form)
      ;; Try to read SOS server name from sos_admin.conf
      server = sos_readConfigFile(detected "SOS_SERVER_NAME")
      if( server != "" then
        sos_guiSetValue(form 'serverField server)
        sos_ok(strcat("Read SOS server from config: " server))
      )
    else
      sos_warn("Could not detect wafer root from current directory.")
      sos_warn("  Please enter it manually.")
    )
  )
)


;;; -----------------------------------------------------------------------------
;;; 3. User Admin callbacks
;;; -----------------------------------------------------------------------------
;;; [Add User(s)] - sos_admin.sh add <group> <user> [user ...]
procedure( sos_guiAddUserCB(form)
  prog( (waferRoot server group users cfg userList serverOpt usersArg scriptArg cfgArg userListArg groupArg cmd)
    waferRoot = sos_guiGetString(form 'waferRootField)
    if( waferRoot == "" then sos_guiAlert("Wafer Root is required.") return(nil) )
    group = sos_guiGetString(form 'groupForUserField)
    if( group == ""     then sos_guiAlert("Group Name is required to add user(s).") return(nil) )
    users = sos_guiGetString(form 'usersField)
    if( users == ""     then sos_guiAlert("User(s) is required.") return(nil) )
    unless( sos_guiRejectNumericUsers("User(s)" users) return(nil) )

    cfg      = sos_guiDeriveCfg(form)
    userList = sos_guiDeriveUserList(form)
    server   = sos_guiGetString(form 'serverField)
    serverOpt = sos_guiServerOpt(server)
    unless( serverOpt return(nil) )
    usersArg = sos_shellQuoteTokenList("User(s)" users)
    unless( usersArg return(nil) )
    scriptArg = sos_shellQuoteArg("sos_admin.sh" strcat(sos_gShellDir "/sos_admin.sh"))
    cfgArg = sos_shellQuoteArg("sosd.cfg" cfg)
    userListArg = sos_shellQuoteArg("user_list" userList)
    groupArg = sos_shellQuoteArg("Group Name" group)
    unless( scriptArg && cfgArg && userListArg && groupArg return(nil) )

    cmd = sprintf(nil
      "bash %s --cfg %s --user-list %s %s add %s %s"
      scriptArg
      cfgArg
      userListArg
      serverOpt
      groupArg
      usersArg)
    return(sos_guiDispatchShell(cmd))
  )
)

;;; [Remove User] - sos_admin.sh remove <group> <user>  (exactly one user)
procedure( sos_guiRemoveUserCB(form)
  prog( (waferRoot server group user cfg userList serverOpt userArg scriptArg cfgArg userListArg groupArg cmd)
    waferRoot = sos_guiGetString(form 'waferRootField)
    if( waferRoot == "" then sos_guiAlert("Wafer Root is required.") return(nil) )
    group = sos_guiGetString(form 'groupForUserField)
    if( group == ""     then sos_guiAlert("Group Name is required to remove a user.") return(nil) )
    user = sos_guiGetString(form 'usersField)
    if( user == ""      then sos_guiAlert("Exactly one user name is required for Remove.") return(nil) )
    unless( sos_guiRejectNumericUsers("User" user) return(nil) )

    cfg      = sos_guiDeriveCfg(form)
    userList = sos_guiDeriveUserList(form)
    server   = sos_guiGetString(form 'serverField)
    serverOpt = sos_guiServerOpt(server)
    unless( serverOpt return(nil) )
    userArg = sos_shellQuoteTokenList("User" user)
    unless( userArg return(nil) )
    scriptArg = sos_shellQuoteArg("sos_admin.sh" strcat(sos_gShellDir "/sos_admin.sh"))
    cfgArg = sos_shellQuoteArg("sosd.cfg" cfg)
    userListArg = sos_shellQuoteArg("user_list" userList)
    groupArg = sos_shellQuoteArg("Group Name" group)
    unless( scriptArg && cfgArg && userListArg && groupArg return(nil) )

    cmd = sprintf(nil
      "bash %s --cfg %s --user-list %s %s remove %s %s"
      scriptArg
      cfgArg
      userListArg
      serverOpt
      groupArg
      userArg)
    return(sos_guiDispatchShell(cmd))
  )
)

;;; [List Groups of User] - sos_admin.sh groups <user>
;;; Uses only the User(s) field; first token is the user name.
procedure( sos_guiListGroupsOfUserCB(form)
  prog( (user cfg userList server serverOpt scriptArg cfgArg userListArg userArg header cmd)
    user = sos_guiGetString(form 'usersField)
    if( user == "" then sos_guiAlert("Please enter a user name to list their groups.") return(nil) )
    user = car(parseString(user " \t"))   ; first token only
    unless( sos_guiRejectNumericUsers("User" user) return(nil) )

    cfg      = sos_guiDeriveCfg(form)
    userList = sos_guiDeriveUserList(form)
    server   = sos_guiGetString(form 'serverField)
    serverOpt = sos_guiServerOpt(server)
    unless( serverOpt return(nil) )
    scriptArg = sos_shellQuoteArg("sos_admin.sh" strcat(sos_gShellDir "/sos_admin.sh"))
    cfgArg = sos_shellQuoteArg("sosd.cfg" cfg)
    userListArg = sos_shellQuoteArg("user_list" userList)
    userArg = sos_shellQuoteArg("User" user)
    header = sos_guiQueryHeader(strcat("Groups for user: " user))
    unless( scriptArg && cfgArg && userListArg && userArg && header return(nil) )

    cmd = sprintf(nil
      "%s\nbash %s --cfg %s --user-list %s %s groups %s"
      header
      scriptArg
      cfgArg
      userListArg
      serverOpt
      userArg)
    return(sos_guiDispatchShell(cmd))
  )
)


;;; -----------------------------------------------------------------------------
;;; 4. Group Admin callbacks
;;; -----------------------------------------------------------------------------
;;; [Add Group] - sos_admin.sh add-group <group>
procedure( sos_guiAddGroupCB(form)
  prog( (waferRoot server group cfg userList serverOpt scriptArg cfgArg userListArg groupArg cmd)
    waferRoot = sos_guiGetString(form 'waferRootField)
    if( waferRoot == "" then sos_guiAlert("Wafer Root is required.") return(nil) )
    group = sos_guiGetString(form 'groupForGroupField)
    if( group == ""     then sos_guiAlert("Group Name is required to add a group.") return(nil) )

    cfg      = sos_guiDeriveCfg(form)
    userList = sos_guiDeriveUserList(form)
    server   = sos_guiGetString(form 'serverField)
    serverOpt = sos_guiServerOpt(server)
    unless( serverOpt return(nil) )
    scriptArg = sos_shellQuoteArg("sos_admin.sh" strcat(sos_gShellDir "/sos_admin.sh"))
    cfgArg = sos_shellQuoteArg("sosd.cfg" cfg)
    userListArg = sos_shellQuoteArg("user_list" userList)
    groupArg = sos_shellQuoteArg("Group Name" group)
    unless( scriptArg && cfgArg && userListArg && groupArg return(nil) )

    cmd = sprintf(nil
      "bash %s --cfg %s --user-list %s %s add-group %s"
      scriptArg
      cfgArg
      userListArg
      serverOpt
      groupArg)
    return(sos_guiDispatchShell(cmd))
  )
)

;;; [Remove Group] - sos_admin.sh remove-group <group>
procedure( sos_guiRemoveGroupCB(form)
  prog( (waferRoot server group cfg userList serverOpt scriptArg cfgArg userListArg groupArg cmd)
    waferRoot = sos_guiGetString(form 'waferRootField)
    if( waferRoot == "" then sos_guiAlert("Wafer Root is required.") return(nil) )
    group = sos_guiGetString(form 'groupForGroupField)
    if( group == ""     then sos_guiAlert("Group Name is required to remove a group.") return(nil) )

    cfg      = sos_guiDeriveCfg(form)
    userList = sos_guiDeriveUserList(form)
    server   = sos_guiGetString(form 'serverField)
    serverOpt = sos_guiServerOpt(server)
    unless( serverOpt return(nil) )
    scriptArg = sos_shellQuoteArg("sos_admin.sh" strcat(sos_gShellDir "/sos_admin.sh"))
    cfgArg = sos_shellQuoteArg("sosd.cfg" cfg)
    userListArg = sos_shellQuoteArg("user_list" userList)
    groupArg = sos_shellQuoteArg("Group Name" group)
    unless( scriptArg && cfgArg && userListArg && groupArg return(nil) )

    cmd = sprintf(nil
      "bash %s --cfg %s --user-list %s %s remove-group %s"
      scriptArg
      cfgArg
      userListArg
      serverOpt
      groupArg)
    return(sos_guiDispatchShell(cmd))
  )
)

;;; [List Users in Group] - sos_admin.sh users <group>
procedure( sos_guiListUsersInGroupCB(form)
  prog( (group cfg userList server serverOpt scriptArg cfgArg userListArg groupArg header cmd)
    group = sos_guiGetString(form 'groupForGroupField)
    if( group == "" then sos_guiAlert("Group Name is required to list users.") return(nil) )

    cfg      = sos_guiDeriveCfg(form)
    userList = sos_guiDeriveUserList(form)
    server   = sos_guiGetString(form 'serverField)
    serverOpt = sos_guiServerOpt(server)
    unless( serverOpt return(nil) )
    scriptArg = sos_shellQuoteArg("sos_admin.sh" strcat(sos_gShellDir "/sos_admin.sh"))
    cfgArg = sos_shellQuoteArg("sosd.cfg" cfg)
    userListArg = sos_shellQuoteArg("user_list" userList)
    groupArg = sos_shellQuoteArg("Group Name" group)
    header = sos_guiQueryHeader(strcat("Users in group: " group))
    unless( scriptArg && cfgArg && userListArg && groupArg && header return(nil) )

    cmd = sprintf(nil
      "%s\nbash %s --cfg %s --user-list %s %s users %s"
      header
      scriptArg
      cfgArg
      userListArg
      serverOpt
      groupArg)
    return(sos_guiDispatchShell(cmd))
  )
)

;;; [List All Groups] - sos_admin.sh list-groups
procedure( sos_guiListAllGroupsCB(form)
  prog( (cfg userList server serverOpt scriptArg cfgArg userListArg header cmd)
    cfg      = sos_guiDeriveCfg(form)
    userList = sos_guiDeriveUserList(form)
    server   = sos_guiGetString(form 'serverField)
    serverOpt = sos_guiServerOpt(server)
    unless( serverOpt return(nil) )
    scriptArg = sos_shellQuoteArg("sos_admin.sh" strcat(sos_gShellDir "/sos_admin.sh"))
    cfgArg = sos_shellQuoteArg("sosd.cfg" cfg)
    userListArg = sos_shellQuoteArg("user_list" userList)
    header = sos_guiQueryHeader("All SOS groups")
    unless( scriptArg && cfgArg && userListArg && header return(nil) )

    cmd = sprintf(nil
      "%s\nbash %s --cfg %s --user-list %s %s list-groups"
      header
      scriptArg
      cfgArg
      userListArg
      serverOpt)
    return(sos_guiDispatchShell(cmd))
  )
)


;;; -----------------------------------------------------------------------------
;;; 5. Workspace sync callback
;;; -----------------------------------------------------------------------------
;;; [Sync Workspaces] - workspace_admin.sh [--log]
;;; Changes to the CDS workspace directory so the script can discover the project
;;; root from $PWD (see workspace_admin.sh discover_project_root).
procedure( sos_guiBuildWorkspaceAdminCmd(waferRoot detailed)
  prog( (currentUser cdsWorkspace workspaceArg waferRootArg scriptArg cmd)
    if( waferRoot == "" then
      sos_guiAlert("Wafer Root is required to sync workspaces.")
      return(nil)
    )
    currentUser = sos_guiCurrentShellUser()
    if( currentUser != "" then
      cdsWorkspace = strcat(waferRoot "/work_libs/" currentUser "/workspace/CDS_workspace")
    else
      cdsWorkspace = waferRoot
    )
    workspaceArg = sos_shellQuoteArg("CDS workspace" cdsWorkspace)
    waferRootArg = sos_shellQuoteArg("Wafer Root" waferRoot)
    scriptArg = sos_shellQuoteArg("workspace_admin.sh" strcat(sos_gShellDir "/workspace_admin.sh"))
    unless( workspaceArg && waferRootArg && scriptArg return(nil) )

    cmd = sprintf(nil
      "if [ -d %s ]; then cd %s; else cd %s; fi && bash %s %s"
      workspaceArg
      workspaceArg
      waferRootArg
      scriptArg
      (if detailed then "--log" else ""))
    return(cmd)
  )
)

procedure( sos_guiBuildSyncWorkspaceCmd(form)
  sos_guiBuildWorkspaceAdminCmd(
    sos_guiGetString(form 'waferRootField)
    sos_guiGetBool(form 'syncLogCheck)
  )
)

procedure( sos_guiSyncWorkspaceCB(form)
  prog( (cmd)
    cmd = sos_guiBuildSyncWorkspaceCmd(form)
    unless( cmd return(nil) )
    return(sos_guiDispatchShell(cmd))
  )
)

procedure( gui_refreshWorkspace()
  prog( (waferRoot cmd)
    waferRoot = sos_detectWaferRoot()
    if( waferRoot == "" then
      sos_guiAlert("Cannot detect Wafer Root from the current Virtuoso working directory.")
      return(nil)
    )
    cmd = sos_guiBuildWorkspaceAdminCmd(waferRoot nil)
    unless( cmd return(nil) )
    sos_guiVisualClearCIW()
    return(sos_runShell(cmd))
  )
)


;;; -----------------------------------------------------------------------------
;;; 6. Form callbacks
;;; -----------------------------------------------------------------------------
procedure( sos_guiApplyCB(form)
  prog( (op opCmd syncCmd combinedCmd)
    sos_guiVisualClearCIW()
    sos_guiRefreshPaths(form)
    sos_guiDeferShellStop()
    op = sos_guiGetString(form 'operationField)
    if( op == "Add" || op == "Remove" then
      sos_guiDeferShellStart()
      opCmd = sos_guiRunSelectedOperation(form)
      when( opCmd
        syncCmd = sos_guiBuildSyncWorkspaceCmd(form)
      )
      sos_guiDeferShellStop()
      unless( opCmd && syncCmd return(nil) )
      combinedCmd = sprintf(nil
        "%s\nrc=$?\nif ((rc == 0)); then\n  %s\nelse\n  exit \"$rc\"\nfi"
        opCmd
        syncCmd)
      sos_runShell(combinedCmd)
    else
      sos_guiDeferShellStop()
      sos_guiRunSelectedOperation(form)
    )
  )
  t
)

procedure( sos_guiResetActionFields(form)
  sos_guiSetValue(form 'operationField "Add")
  sos_guiSetValue(form 'groupForUserField "")
  sos_guiSetValue(form 'groupForGroupField "")
  sos_guiSetValue(form 'usersField "")
  sos_guiSetValue(form 'syncLogCheck nil)
  t
)

procedure( sos_guiChoicesForMode(mode)
  if( mode == "Group Admin" then
    list("Add" "Remove" "Query" "List All")
  else
    list("Add" "Remove" "Query")
  )
)

procedure( sos_guiRefreshOperationChoices(form)
  let( (opField mode)
    opField = sos_guiGetField(form 'operationField)
    mode = sos_guiGetString(form 'adminModeField)
    when(opField
      ;; Ref: Cadence User Interface SKILL Functions Reference - cyclic fields.
      ;; Cyclic field objects expose their choices through the choices slot.
      opField->choices = sos_guiChoicesForMode(mode)
    )
  )
  t
)

procedure( sos_guiUpdateLogState(form)
  let( (op logField enabled)
    op = sos_guiGetString(form 'operationField)
    enabled = (op == "Add" || op == "Remove")
    logField = sos_guiGetField(form 'syncLogCheck)
    when(logField
      ;; Ref: local verified Virtuoso GUI pattern - hiSetFieldEnabled(field bool).
      hiSetFieldEnabled(logField enabled)
      unless(enabled
        logField->value = nil
      )
    )
  )
  t
)

procedure( sos_guiClearTextInputs(form)
  sos_guiSetValue(form 'groupForUserField "")
  sos_guiSetValue(form 'groupForGroupField "")
  sos_guiSetValue(form 'usersField "")
  t
)

procedure( sos_guiSyncToggleCB(form)
  ;; Backward-compatible no-op for stale form callbacks after script reloads.
  sos_guiUpdateLogState(form)
  t
)

procedure( sos_guiLogToggleCB(form)
  let( (op)
    op = sos_guiGetString(form 'operationField)
    unless( op == "Add" || op == "Remove"
      sos_guiSetValue(form 'syncLogCheck nil)
    )
    sos_guiUpdateLogState(form)
  )
  t
)

;;; Toggle the compact Action panel between User Admin and Group Admin controls.
procedure( sos_guiSetVisible(form fieldSym visible)
  let( (fh)
    fh = sos_guiGetField(form fieldSym)
    when(fh
      fh->invisible = if(visible then nil else t)
    )
  )
)

procedure( sos_guiSetEnabled(form fieldSym enabled)
  let( (fh)
    fh = sos_guiGetField(form fieldSym)
    when(fh
      ;; Ref: local verified Virtuoso GUI pattern - hiSetFieldEnabled(field bool).
      hiSetFieldEnabled(fh enabled)
    )
  )
)

procedure( sos_guiSelectAdminMode(form mode)
  sos_guiSetValue(form 'adminModeField mode)
  sos_guiSetValue(form 'userAdminCheck (mode == "User Admin"))
  sos_guiSetValue(form 'groupAdminCheck (mode == "Group Admin"))
  sos_guiResetActionFields(form)
  sos_guiRefreshOperationChoices(form)
  sos_guiAdminModeCB(form)
  t
)

procedure( sos_guiUserAdminCheckCB(form)
  if( sos_guiGetBool(form 'userAdminCheck) then
    sos_guiSelectAdminMode(form "User Admin")
  else
    unless( sos_guiGetBool(form 'groupAdminCheck)
      sos_guiSelectAdminMode(form "User Admin")
    )
  )
  t
)

procedure( sos_guiGroupAdminCheckCB(form)
  if( sos_guiGetBool(form 'groupAdminCheck) then
    sos_guiSelectAdminMode(form "Group Admin")
  else
    unless( sos_guiGetBool(form 'userAdminCheck)
      sos_guiSelectAdminMode(form "Group Admin")
    )
  )
  t
)

procedure( sos_guiOperationCB(form)
  let( (mode op userQuery groupListAll userGroupEnabled groupGroupEnabled usersEnabled)
    mode = sos_guiGetString(form 'adminModeField)
    op = sos_guiGetString(form 'operationField)
    userQuery = (mode == "User Admin" && op == "Query")
    groupListAll = (mode == "Group Admin" && op == "List All")
    userGroupEnabled = (mode == "User Admin" && !userQuery)
    groupGroupEnabled = (mode == "Group Admin" && !groupListAll)
    usersEnabled = (mode == "User Admin")
    sos_guiSetEnabled(form 'groupForUserField userGroupEnabled)
    sos_guiSetEnabled(form 'groupForGroupField groupGroupEnabled)
    sos_guiSetEnabled(form 'usersField usersEnabled)
    unless(userGroupEnabled
      sos_guiSetValue(form 'groupForUserField "")
    )
    unless(groupGroupEnabled
      sos_guiSetValue(form 'groupForGroupField "")
    )
    unless(usersEnabled
      sos_guiSetValue(form 'usersField "")
    )
    sos_guiUpdateLogState(form)
  )
  t
)

procedure( sos_guiAdminModeCB(form)
  let( (mode userMode groupMode)
    mode = sos_guiGetString(form 'adminModeField)
    userMode = (mode != "Group Admin")
    groupMode = (mode == "Group Admin")

    sos_guiSetVisible(form 'groupForUserField userMode)
    sos_guiSetVisible(form 'usersField t)

    sos_guiSetVisible(form 'groupForGroupField groupMode)
    sos_guiRefreshOperationChoices(form)
    sos_guiOperationCB(form)
  )
)

procedure( sos_guiRunSelectedOperation(form)
  prog( (mode op group)
    unless( boundp('sos_gDeferShellRun) && sos_gDeferShellRun
      sos_guiDeferShellStop()
    )
    mode = sos_guiGetString(form 'adminModeField)
    op = sos_guiGetString(form 'operationField)

    if( mode == "Group Admin" then
      group = sos_guiGetString(form 'groupForGroupField)
      sos_guiSetValue(form 'groupForUserField group)
      return(
        cond(
          (op == "Add"      sos_guiAddGroupCB(form))
          (op == "Remove"   sos_guiRemoveGroupCB(form))
          (op == "List All" sos_guiListAllGroupsCB(form))
          (t                sos_guiListUsersInGroupCB(form))
        )
      )
    else
      group = sos_guiGetString(form 'groupForUserField)
      sos_guiSetValue(form 'groupForGroupField group)
      return(
        cond(
          (op == "Add"    sos_guiAddUserCB(form))
          (op == "Remove" sos_guiRemoveUserCB(form))
          (t              sos_guiListGroupsOfUserCB(form))
        )
      )
    )
  )
)

;;; -----------------------------------------------------------------------------
;;; 7. Main form
;;; -----------------------------------------------------------------------------
;;; This constructor uses the compact 2D layout used by the public form entry point.
procedure( sos_createAdminForm()
  let( (form)
    form = hiCreateAppForm(
      ?name       'sosAdminMainForm
      ?formTitle  "SOS Administration"
      ;; Ref: Cadence User Interface SKILL Functions Reference - hiCreateAppForm.
      ;; buttonLayout: ApplyCancel omits Defaults and keeps
      ;; the automatically added Help button for nonoptions forms.
      ?buttonLayout 'ApplyCancel
      ?callback   "sos_guiApplyCB(sos_gAdminForm)"
      ?fields     list(
        ;; Ref: Cadence User Interface SKILL Functions Reference,
        ;; Forms - 2D form layout with frame fields.
        list(
          hiCreateFrameField(
            ?name      'configFrame
            ?labelText "Configuration"
          )
          25:0 585:205 20
        )
        list(
          hiCreateStringField(
            ?name      'waferRootField
            ?prompt    "Wafer Root"
            ?value     sos_detectWaferRoot()
            ?defValue  "/project/Design_Data/<WaferID>"
            ?editable  nil
            ;; Ref: Cadence User Interface SKILL Functions Reference - hiCreateStringField.
            ;; The callback runs when the type-in field loses
            ;; focus or when a form button is selected.
            ?callback  "sos_guiRefreshPaths(sos_gAdminForm)"
          )
          55:35 530:30 80
        )
        list(
          hiCreateStringField(
            ?name      'serverField
            ?prompt    "SOS Server"
            ?value     sos_detectSosServer()
            ?defValue  "<auto>"
            ?editable  nil
          )
          55:75 530:30 80
        )
        list(
          hiCreateStringField(
            ?name      'cfgLabel
            ?prompt    "sosd.cfg"
            ?value     "(will be set automatically)"
            ?defValue  "(will be set automatically)"
            ?editable  nil
          )
          55:115 530:30 80
        )
        list(
          hiCreateStringField(
            ?name      'userListLabel
            ?prompt    "user_list"
            ?value     "(will be set automatically)"
            ?defValue  "(will be set automatically)"
            ?editable  nil
          )
          55:155 530:30 80
        )

        list(
          hiCreateFrameField(
            ?name      'actionFrame
            ?labelText "Action"
          )
          25:220 585:205 20
        )
        list(
          hiCreateFrameField(
            ?name      'adminPanelFrame
            ?labelText ""
          )
          55:264 530:138 20
        )
        list(
          hiCreateBooleanButton(
            ?name           'userAdminCheck
            ?buttonText     "User Admin"
            ?buttonLocation 'left
            ?value          t
            ?callback       "sos_guiUserAdminCheckCB(sos_gAdminForm)"
          )
          55:241 100:24
        )
        list(
          hiCreateBooleanButton(
            ?name           'groupAdminCheck
            ?buttonText     "Group Admin"
            ?buttonLocation 'left
            ?value          nil
            ?callback       "sos_guiGroupAdminCheckCB(sos_gAdminForm)"
          )
          155:241 115:24
        )
        list(
          hiCreateStringField(
            ?name      'adminModeField
            ?value     "User Admin"
            ?defValue  "User Admin"
            ?invisible t
          )
          55:241 1:1 0
        )
        list(
          ;; Ref: Cadence User Interface SKILL Functions Reference - hiCreateCyclicField.
          ;; hiCreateCyclicField creates a compact single-choice selector.
          hiCreateCyclicField(
            ?name      'operationField
            ?prompt    "Operation"
            ?choices   list("Add" "Remove" "Query")
            ?value     "Add"
            ?callback  "sos_guiOperationCB(sos_gAdminForm)"
          )
          70:279 220:30 80
        )
        list(
          hiCreateBooleanButton(
            ?name           'syncLogCheck
            ?buttonText     "Log"
            ?buttonLocation 'left
            ?value          nil
            ?callback       "sos_guiLogToggleCB(sos_gAdminForm)"
          )
          285:279 70:30
        )
        list(
          hiCreateStringField(
            ?name      'groupForUserField
            ?prompt    "Group Name"
            ?value     ""
            ?defValue  ""
          )
          70:314 500:30 80
        )
        list(
          hiCreateStringField(
            ?name      'usersField
            ?prompt    "User(s)"
            ?value     ""
            ?defValue  ""
          )
          70:349 500:30 80
        )

        list(
          hiCreateStringField(
            ?name      'groupForGroupField
            ?prompt    "Group Name"
            ?value     ""
            ?defValue  ""
            ?invisible t
          )
          70:314 500:30 80
        )
      )
      ?initialSize list(635 455)
      ?minSize     list(635 455)
      ;; Ref: Cadence Community / Andrew Beckett: for hiDisplayForm app forms,
      ;; setting minSize and maxSize to the same dimensions makes the form
      ;; non-resizable.
      ?maxSize     list(635 455)
    )
    setq( sos_gAdminForm form )
    sos_guiDeferShellStop()
    sos_guiRefreshPaths(form)
    sos_guiUpdateLogState(form)
    sos_guiAdminModeCB(form)
    form
  )
)


procedure( gui_addPeople()
  sos_guiDeferShellStop()
  when( boundp('sos_gAdminForm) && sos_gAdminForm
    ;; Ref: Cadence User Interface SKILL Functions Reference - hiDeleteForm:
    ;; delete the old form object before recreating it so a reloaded GUI script
    ;; does not keep displaying a stale cached form.
    hiDeleteForm(sos_gAdminForm)
    setq( sos_gAdminForm nil )
  )
  sos_createAdminForm()
  when( sos_gAdminForm
    sos_guiRefreshPaths(sos_gAdminForm)
    hiDisplayForm(sos_gAdminForm)
  )
)


printf("[gui_add_people.il] Loaded.\n")
