;;; =============================================================================
;;; sos_utils.il - SOS Program Manage: shared utility functions
;;;
;;; Mirrors the design of ct_utils.il from CAD Tools Suite.
;;; All public symbols are prefixed with "sos_" to avoid namespace collisions.
;;;
;;; Changelog:
;;;   v1.0  Initial release.  Provides path resolution, user enumeration,
;;;         string/list helpers, and uniform CIW log procedures.
;;; =============================================================================


;;; ----
;;; sos_getEnv
;;; Read a shell environment variable through the documented SKILL API.
;;; Returns "" when the variable is unset.
;;; ----
procedure( sos_getEnv(name)
  let( (value)
    ;; Ref: doc/sklangref_01.pdf - Environment Functions: getShellEnvVar.
    value = getShellEnvVar(name)
    if(value then value else "")
  )
)


;;; ----
;;; sos_findProjRoot
;;; Walk up from cwd to locate a directory named "sos_project" (or any
;;; directory containing a file ".sos_root" as a sentinel).
;;; Returns absolute path string, or nil on failure.
;;; ----
procedure( sos_findProjRoot()
  let( (path found sentinel)
    path     = getWorkingDir()
    found    = nil
    sentinel = ".sos_root"
    while( path != "/"
      when( isFile( strcat(path "/" sentinel) ) ||
            isDir(  strcat(path "/sos_project") )
        found = path
        path  = "/"          ; break
      )
      path = simplifyFilename( strcat(path "/..") )
    )
    found
  )
)


;;; ----
;;; sos_getProjRoot
;;; Returns the project root, using sos_gProjRoot global if already set and
;;; valid, otherwise auto-detecting via sos_findProjRoot().
;;; ----
procedure( sos_getProjRoot()
  unless( boundp('sos_gProjRoot) && sos_gProjRoot && isDir(sos_gProjRoot)
    setq( sos_gProjRoot sos_findProjRoot() )
  )
  sos_gProjRoot
)


;;; ----
;;; sos_getPeopleDir
;;; Returns the absolute path to the "people" sub-directory under the project
;;; root.  This is the canonical store for per-person configuration files.
;;; Returns nil if the project root cannot be resolved.
;;; ----
procedure( sos_getPeopleDir()
  let( (root)
    root = sos_getProjRoot()
    if( root
      then strcat(root "/sos_project/people")
      else nil
    )
  )
)


;;; ----
;;; sos_getPersonList
;;; Returns a sorted list of person names (directory entries) under the
;;; people directory.  Excludes entries listed in sos_gExcludePersons.
;;; Returns nil (with a warning) if the people directory is not found.
;;; ----
procedure( sos_getPersonList()
  let( (dir entries persons excl)
    dir = sos_getPeopleDir()
    if( dir && isDir(dir)
      then
        excl    = if( boundp('sos_gExcludePersons) then sos_gExcludePersons else nil )
        entries = getDirFiles(dir)
        persons = nil
        foreach( e entries
          when( e != "." && e != ".."
               && isDir( strcat(dir "/" e) )
               && !member(e excl)
            persons = append1(persons e)
          )
        )
        sort(persons 'alphalessp)
      else
        printf("[sos_utils] WARNING: people directory not found: %s\n"
               if(dir then dir else "<unresolved>"))
        nil
    )
  )
)


;;; ----
;;; sos_resolveProjPath
;;; If input starts with '/', use as-is (absolute).
;;; Otherwise: sos_gProjBaseRoot / input
;;; Mirrors ct_resolveProjPath from ct_utils.il.
;;; ----
procedure( sos_resolveProjPath(input)
  let( (baseRoot)
    baseRoot = if( boundp('sos_gProjBaseRoot) && sos_gProjBaseRoot
                   then sos_gProjBaseRoot
                   else "/project/SOS" )
    if( rexMatchp("^/" input)
      then input
      else strcat(baseRoot "/" input)
    )
  )
)


;;; ----
;;; sos_listToString  (SKILL list - space-separated string)
;;; Identical contract to ct_listToString.
;;; ----
procedure( sos_listToString(lst)
  let( (result)
    result = ""
    foreach( item lst
      result = strcat(result (if result == "" then "" else " ") item)
    )
    result
  )
)


;;; ----
;;; sos_stringToList  (space/comma-separated string - list of non-empty tokens)
;;; Identical contract to ct_stringToList.
;;; ----
procedure( sos_stringToList(str)
  let( (tokens)
    tokens = parseString(str " ,\t\n")
    setof( p tokens  p != "" )
  )
)


;;; ----
;;; sos_banner - print a formatted section header to CIW
;;; ----
procedure( sos_banner(title)
  printf("\n")
  printf("=============================================================\n")
  printf("  %s\n" title)
  printf("=============================================================\n")
)


;;; ----
;;; sos_ok / sos_err / sos_warn - uniform CIW log helpers
;;; ----
procedure( sos_ok(msg)   printf("[OK]   %s\n" msg) )
procedure( sos_err(msg)  printf("[ERR]  %s\n" msg) )
procedure( sos_warn(msg) printf("[WARN] %s\n" msg) )


;;; ----
;;; sos_detectWaferRoot
;;; Walk up from Virtuoso working directory to locate a wafer root matching
;;; the pattern /project/Design_Data/<WaferID>.
;;; Returns string on success, or "" on failure.
;;; ----
procedure( sos_detectWaferRoot()
  let( (dir wafer parts)
    dir = getWorkingDir()
    wafer = ""
    while( dir != "/" && dir != "" && wafer == ""
      when( rexMatchp("^/project/Design_Data/[^/]+" dir)
        ;; Ref: doc/sklangref_01.pdf - String Functions: rexMatchp, parseString, strcat.
        ;; rexMatchp is used only as a predicate; rebuild the matched prefix
        ;; from path components so the caller always receives a string.
        parts = parseString(dir "/")
        when( length(parts) >= 3
          wafer = strcat("/" car(parts) "/" cadr(parts) "/" caddr(parts))
        )
      )
      dir = simplifyFilename(strcat(dir "/.."))
    )
    wafer
  )
)


;;; ----
;;; sos_strTrim
;;; Trim leading and trailing whitespace from a string.
;;; ----
procedure( sos_strTrim(str)
  let( (tokens)
    ;; Ref: doc/sklangref_01.pdf - String Functions: parseString.
    ;; This trim is intentionally token-oriented because sos_admin.conf values
    ;; used by the GUI are scalar names/paths, not free-form text.
    tokens = parseString(if(str then str else "") " \t\n")
    if(tokens then car(tokens) else "")
  )
)


;;; ----
;;; sos_readConfigFile
;;; Read a KEY=VALUE entry from sos_admin.conf under the given wafer root.
;;; Returns the value as a string, or "" if the config file / key is not found.
;;; Handles optional surrounding quotes and inline comments (after #).
;;; ----
procedure( sos_readConfigFile(waferRoot key)
  let( (configPath port line value kvParts keyPart valuePart commentParts)
    configPath = strcat(waferRoot "/config/user_config/sos_admin.conf")
    unless( isFile(configPath) return("") )
    port = infile(configPath)
    unless(port return(""))
    value = ""
    while( gets(line port) && value == ""
      kvParts = parseString(line "=")
      when( length(kvParts) >= 2
        keyPart = sos_strTrim(car(kvParts))
        when( keyPart == key
          valuePart = cadr(kvParts)
          commentParts = parseString(valuePart "#")
          if( commentParts
            then line = sos_strTrim(car(commentParts))
            else line = sos_strTrim(valuePart)
          )
          when( strlen(line) >= 2
            if( (rexMatchp("^\"" line) && rexMatchp("\"$" line))
                || (rexMatchp("^'" line) && rexMatchp("'$" line))
              then line = substring(line 2 sub1(strlen(line)))
            )
          )
          value = line
        )
      )
    )
    close(port)
    value
  )
)


;;; ----
;;; sos_detectSosServer
;;; Resolve SOS server name, trying in order:
;;;   1. Environment variable SOS_SERVER_NAME
;;;   2. Environment variable SOS_SERVER
;;;   3. sos_admin.conf under the detected wafer root
;;; Returns string on success, or "" on failure.
;;; ----
procedure( sos_detectSosServer()
  let( (server waferRoot)
    server = sos_getEnv("SOS_SERVER_NAME")
    if( server == "" then
      server = sos_getEnv("SOS_SERVER")
    )
    if( server == "" then
      waferRoot = sos_detectWaferRoot()
      if( waferRoot != "" then
        server = sos_readConfigFile(waferRoot "SOS_SERVER_NAME")
      )
    )
    server
  )
)


printf("[sos_utils.il] Loaded.\n")
