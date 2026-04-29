;;; =============================================================================
;;; sos_runner.il - SOS Program Manage: shell execution layer
;;;
;;; Mirrors the design of ct_runner.il from CAD Tools Suite.
;;;
;;; KEY DESIGN (same as ct_runner.il):
;;;   ipcBeginProcess in IC23.1 tokenises the command string on whitespace and
;;;   does NOT invoke a shell, so quoted arguments are not preserved.
;;;   Work-around: write the real command to a temporary bash script and run
;;;     bash /tmp/sos_run.sh
;;;   bash then parses the script content with full quoting support.
;;;
;;; ipcBeginProcess signature (skipcref.pdf / comp.cad.cadence):
;;;   ipcBeginProcess( t_command
;;;                    [ t_hostName ]
;;;                    [ tsu_dataHandler ]   stdout callback: procedure(pid data)
;;;                    [ tsu_errHandler ]    stderr callback: procedure(pid data)
;;;                    [ tsu_postFunc ]      exit callback
;;;                    [ t_logFile ] )
;;;
;;; Changelog:
;;;   v1.0  Initial release.  sos_runShell + sos_buildCmd helpers.
;;;         stderr callback (sos_runnerErrCB) included from day-one to avoid
;;;         the silent-stderr bug that ct_runner.il fixed in v1.1.
;;; =============================================================================


;;; Temporary script path - computed per invocation inside sos_runShell() to
;;; avoid cross-process races.
;;; Former global variable sos_gTmpScript removed for safety.


;;; -----------------------------------------------------------------------------
;;; Subprocess stdout to CIW
;;; -----------------------------------------------------------------------------
procedure( sos_runnerDataCB(pid data)
  printf("%s" data)
)


;;; -----------------------------------------------------------------------------
;;; Subprocess stderr to CIW (prefixed with [ERR])
;;; -----------------------------------------------------------------------------
;;; Explicitly capturing stderr prevents errors in background scripts from being
;;; silently discarded (the silent-stderr pitfall seen in ct_runner.il v1.0).
procedure( sos_runnerErrCB(pid data)
  printf("[ERR] %s" data)
)


;;; -----------------------------------------------------------------------------
;;; Write command to temp script and execute via bash
;;; -----------------------------------------------------------------------------
;;; cmd - a single string containing the full shell command to run.
;;;        May contain quotes, env-var expansions, pipes, etc.; bash handles all
;;;        of that correctly when it parses the script file.
procedure( sos_runShell(cmd)
  let( (tmpScript port)
    ;; Per-invocation unique temp path avoids cross-process races.
    ;; Ref: doc/sklangref_01.pdf - Input/Output Functions: makeTempFileName.
    tmpScript = makeTempFileName("/tmp/sos_program_manage_run")

    ;; Persist the command in a temp script so bash parses quoting properly.
    port = outfile(tmpScript "w")
    if( port then
      fprintf(port "#!/bin/bash\n%s\n" cmd)
      close(port)
    else
      sos_err(strcat("Cannot create temporary shell script: " tmpScript))
      return(nil)
    )

    ;; Launch the script asynchronously.
    ;; arg1  command string - splits cleanly as: execv("bash", ["bash", path])
    ;; arg2  "" - run on local host
    ;; arg3  dataHandler - sos_runnerDataCB  (stdout - CIW)
    ;; arg4  errHandler - sos_runnerErrCB   (stderr - CIW, [ERR] prefix)
    ;; arg5  postFunc - nil (no exit-time action needed yet)
    ipcBeginProcess(
      strcat("bash " tmpScript)
      ""
      'sos_runnerDataCB
      'sos_runnerErrCB
      nil
    )
    t
  )
)


;;; -----------------------------------------------------------------------------
;;; Build a shell command string from a SKILL list of tokens
;;; -----------------------------------------------------------------------------
;;; sos_buildCmd( list("sudo" "/scripts/sos_add_people.sh" "--name" "Alice") )
;;; returns "sudo /scripts/sos_add_people.sh --name Alice"
;;; Delegates to sos_listToString for consistent token joining.
procedure( sos_buildCmd(tokens)
  sos_listToString(tokens)
)


printf("[sos_runner.il] Loaded.\n")
