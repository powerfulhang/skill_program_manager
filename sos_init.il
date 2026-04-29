;;; =============================================================================
;;; sos_init.il - SOS Program Manage: main entry point
;;;
;;; Usage in CIW:
;;;   load("/your/path/to/sos_tools/skill/sos_init.il")
;;;
;;; Or add to .cdsinit:
;;;   load("/your/path/to/sos_tools/skill/sos_init.il")
;;;
;;; Menu strategy (mirrors cad_tools_init.il, per Andrew Beckett / Cadence):
;;; - deRegUserTriggers 3rd-arg "user menu trigger" for schematic / maskLayout
;;;     Virtuoso calls the procedure when creating each window; we return
;;;       list(menu), and Virtuoso inserts it automatically.
;;; - CIW: hiInsertBannerMenu into hiGetCIWindow() immediately at load time.
;;; - The pulldown menu object is created once (lazily on first call) and
;;;     cached in sos_gSosProgramMenu.  Subsequent calls return the cached
;;;     object so that menu items are never duplicated across multiple windows.
;;; =============================================================================


;;; -----------------------------------------------------------------------------
;;; 1. Configuration - EDIT THIS BLOCK FOR YOUR SITE

;;; Absolute path to the CAD_Tools scripts root directory.
;;; Default server layout:
;;;   <root>/skill - SKILL files
;;;   <root>/shell - shell backend scripts
setq( sos_gToolRoot   "/CAD_Tools/scripts" )

;;; Derived sub-paths (do not edit unless your layout differs)
setq( sos_gSkillDir   strcat(sos_gToolRoot "/skill") )
setq( sos_gShellDir   strcat(sos_gToolRoot "/shell") )

;;; Project base root used by sos_resolveProjPath (sos_utils.il)
setq( sos_gProjBaseRoot "/project/SOS" )       ; <-- adjust to your project path

;;; Persons to exclude from enumeration (e.g. service / temp accounts)
setq( sos_gExcludePersons list("temp_person") )


;;; -----------------------------------------------------------------------------
;;; 2. Module loader

procedure( sos_loadModules()
  let( (modules failed failedStr fullPath)
    modules = list(
      "sos_utils.il"
      "sos_runner.il"
      "gui_add_people.il"       ; SOS Administration dialog
      ;;; Future modules go here, e.g.:
      ;;;   "gui_remove_people.il"
      ;;;   "gui_list_people.il"
    )
    failed    = nil
    failedStr = ""
    foreach( m modules
      fullPath = strcat(sos_gSkillDir "/" m)
      if( isFile(fullPath)
        then load(fullPath)
        else
          printf("[SOS Program Manage] WARNING: module not found: %s\n" fullPath)
          failed = append1(failed m)
      )
    )
    when( failed
      foreach( m failed
        failedStr = strcat(failedStr (if failedStr == "" then "" else " ") m)
      )
      printf("[SOS Program Manage] %d module(s) failed to load: %s\n"
             length(failed) failedStr)
    )
  )
)


;;; -----------------------------------------------------------------------------
;;; 3. Pulldown menu object
;;;
;;; sos_createSosProgramMenu() builds the hiCreatePulldownMenu object once and
;;; caches it in sos_gSosProgramMenu.  Subsequent calls return the cached object
;;; so that menu items are never duplicated when multiple windows are opened.
;;;
;;; Current menu layout:
;;;
;;;   SOS Program Manage
;;; - SOS Administration...         entry point (gui_addPeople)
;;; - Refresh Workspace             entry point (gui_refreshWorkspace)
;;; - Reload SOS Tools

procedure( sos_createRefreshWorkspaceMenuItem()
  hiCreateMenuItem(
    ?name     'sosMenuRefreshWorkspace
    ?itemText "Refresh Workspace"
    ?callback "gui_refreshWorkspace()"
    ;;; gui_refreshWorkspace() is defined in gui_add_people.il.
    ;;; The stub below is active until that module is loaded.
  )
)

procedure( sos_ensureRefreshWorkspaceMenuItem(menu)
  when( menu
    unless( hiIsMenuItemEnabled(menu 'sosMenuRefreshWorkspace)
      ;; Ref: Cadence User Interface SKILL Functions Reference - Menus:
      ;; hiInsertMenuItem(r_hiMenu r_menuItem g_position) inserts a menu item
      ;; into all instances of the menu after the given item handle.
      hiInsertMenuItem(
        menu
        sos_createRefreshWorkspaceMenuItem()
        'sosMenuAddPeople
      )
    )
  )
)

procedure( sos_createSosProgramMenu()
  if( boundp('sos_gSosProgramMenu) && sos_gSosProgramMenu then
    sos_ensureRefreshWorkspaceMenuItem(sos_gSosProgramMenu)
  else
    setq( sos_gSosProgramMenu
      hiCreatePulldownMenu(
        'sosProgramMenu
        "SOS Program Manage"
        list(

          ;;; Administration
          hiCreateMenuItem(
            ?name     'sosMenuAddPeople
            ?itemText "SOS Administration..."
            ?callback "gui_addPeople()"
            ;;; gui_addPeople() is defined in gui_add_people.il.
            ;;; The stub below is active until that module is loaded.
          )

          sos_createRefreshWorkspaceMenuItem()

          ;;; Future menu items can be inserted here, e.g.
          ;;;   hiCreateMenuItem(
          ;;;     ?name     'sosMenuRemovePeople
          ;;;     ?itemText "Remove People..."
          ;;;     ?callback "gui_removePeople()"
          ;;;   )
          ;;;   hiCreateMenuItem(
          ;;;     ?name     'sosMenuListPeople
          ;;;     ?itemText "List People..."
          ;;;     ?callback "gui_listPeople()"
          ;;;   )

          ;;; Separator before maintenance items
          hiCreateSeparatorMenuItem( ?name 'sosSep1 )

          ;;; Reload (maintenance)
          hiCreateMenuItem(
            ?name     'sosMenuReload
            ?itemText "Reload SOS Tools"
            ?callback sprintf(nil "load(\"%s/sos_init.il\")" sos_gSkillDir)
          )
        )
      )
    )
  )
  sos_ensureRefreshWorkspaceMenuItem(sos_gSosProgramMenu)
  sos_gSosProgramMenu
)


;;; -----------------------------------------------------------------------------
;;; 4. User menu trigger
;;;
;;; Registered as the 3rd argument of deRegUserTriggers (the "user menu
;;; trigger").  Virtuoso calls this automatically whenever a new schematic or
;;; maskLayout window is created.  Returning list(menu) tells Virtuoso to insert
;;; that pulldown into the window's banner; no manual hiInsertBannerMenu needed
;;; for Design Editor windows.
;;;
;;; Pattern source: cad_tools_init.il / Andrew Beckett recommendation.

procedure( sos_userMenuTrigger(args)
  list( sos_createSosProgramMenu() )
)


;;; -----------------------------------------------------------------------------
;;; 5. Register triggers for editor windows
;;;
;;; deRegUserTriggers( t_editorType  s_appTrigger  s_menuTrigger )
;;;   arg 1 - editor type string
;;;   arg 2 - user application trigger (nil = none)
;;;   arg 3 - user menu trigger (our hook)

deRegUserTriggers( "schematic"  nil 'sos_userMenuTrigger )
deRegUserTriggers( "maskLayout" nil 'sos_userMenuTrigger )


;;; -----------------------------------------------------------------------------
;;; 6. Insert into CIW at load time
;;;
;;; deRegUserTriggers fires only for Design Editor windows, not the CIW itself.
;;; Insert the menu directly here so it is accessible immediately after loading,
;;; without requiring the user to open a schematic or layout window first.

let( (menu ciw)
  menu = sos_createSosProgramMenu()
  ciw  = hiGetCIWindow()
  when( ciw
    unless( member(menu hiGetBannerMenus(ciw))
      hiInsertBannerMenu(
        ciw
        menu
        length( hiGetBannerMenus(ciw) )   ; append after the last existing menu
      )
      printf("[SOS Program Manage] Menu inserted into CIW.\n")
    )
  )
)


;;; -----------------------------------------------------------------------------
;;; 7. Banner

procedure( sos_printBanner()
  printf("\n")
  printf("+----------------------------------------------------------+\n")
  printf("|        SOS Program Manage - Virtuoso                  |\n")
  printf("+----------------------------------------------------------+\n")
  printf("|  Root  : %-47s|\n" strcat(sos_gToolRoot " "))
  printf("|  Shell : %-47s|\n" strcat(sos_gShellDir " "))
  printf("+----------------------------------------------------------+\n")
  printf("|  gui_addPeople()      SOS Administration                |\n")
  printf("|  gui_refreshWorkspace() Refresh Workspace               |\n")
  printf("+----------------------------------------------------------+\n")
  printf("|  Menu: 'SOS Program Manage' in CIW + schematic          |\n")
  printf("|         + maskLayout                                     |\n")
  printf("+----------------------------------------------------------+\n\n")
)


;;; -----------------------------------------------------------------------------
;;; 8. Stub: gui_addPeople
;;;
;;; This procedure is the placeholder entry point for SOS Administration.
;;; It is defined here so that the menu item callback (gui_addPeople()) is
;;; always resolvable even before gui_add_people.il is fully written.
;;;
;;; Once gui_add_people.il is implemented and loaded by sos_loadModules(), that
;;; file should redefine gui_addPeople() with the real dialog logic; this stub
;;; will be silently shadowed (last definition wins in SKILL).

procedure( gui_addPeople()
  hiDisplayAppDBox(
    ?name        'sosAddPeopleStub
    ?dboxBanner  "SOS Administration"
    ?fields      list(
                   hiCreateLabel(
                     ?name    'stubLabel
                     ?labelText
                       "SOS Administration is not loaded yet.\nPlease reload SOS Tools."
                   )
                 )
    ?dialogStyle 'modal
    ?buttonLayout 'Close
  )
)

procedure( gui_refreshWorkspace()
  hiDisplayAppDBox(
    ?name        'sosRefreshWorkspaceStub
    ?dboxBanner  "Refresh Workspace"
    ?fields      list(
                   hiCreateLabel(
                     ?name    'refreshWorkspaceStubLabel
                     ?labelText
                       "Refresh Workspace is not loaded yet.\nPlease reload SOS Tools."
                   )
                 )
    ?dialogStyle 'modal
    ?buttonLayout 'Close
  )
)


;;; -----------------------------------------------------------------------------
;;; 9. Bootstrap

sos_loadModules()
sos_printBanner()
