#if windows
  $ PYTHONPATH="$TESTDIR/../contrib;$PYTHONPATH"
#else
  $ PYTHONPATH="$TESTDIR/../contrib:$PYTHONPATH"
#endif
  $ export PYTHONPATH

typical client does not want echo-back messages, so test without it:

  $ grep -v '^promptecho ' < $HGRCPATH >> $HGRCPATH.new
  $ mv $HGRCPATH.new $HGRCPATH

  $ hg init repo
  $ cd repo

  >>> from __future__ import absolute_import, print_function
  >>> import os
  >>> import sys
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def hellomessage(server):
  ...     ch, data = readchannel(server)
  ...     print('%c, %r' % (ch, data))
  ...     # run an arbitrary command to make sure the next thing the server
  ...     # sends isn't part of the hello message
  ...     runcommand(server, ['id'])
  o, 'capabilities: getencoding runcommand\nencoding: *\npid: *' (glob)
  *** runcommand id
  000000000000 tip

  >>> from hgclient import check
  >>> @check
  ... def unknowncommand(server):
  ...     server.stdin.write('unknowncommand\n')
  abort: unknown command unknowncommand

  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def checkruncommand(server):
  ...     # hello block
  ...     readchannel(server)
  ... 
  ...     # no args
  ...     runcommand(server, [])
  ... 
  ...     # global options
  ...     runcommand(server, ['id', '--quiet'])
  ... 
  ...     # make sure global options don't stick through requests
  ...     runcommand(server, ['id'])
  ... 
  ...     # --config
  ...     runcommand(server, ['id', '--config', 'ui.quiet=True'])
  ... 
  ...     # make sure --config doesn't stick
  ...     runcommand(server, ['id'])
  ... 
  ...     # negative return code should be masked
  ...     runcommand(server, ['id', '-runknown'])
  *** runcommand 
  Mercurial Distributed SCM
  
  hg COMMAND [OPTIONS]
  
  These are some common Mercurial commands.  Use 'hg help commands' to list all
  commands, and 'hg help COMMAND' to get help on a specific command.
  
  Get the latest commits from the server:
  
   pull          pull changes from the specified source
  
  View commits:
  
   show          show commit in detail
   diff          show differences between commits
  
  Check out a commit:
  
   checkout      check out a specific commit
  
  Work with your checkout:
  
   status        list files with pending changes
   add           start tracking the specified files
   remove        delete the specified tracked files
   forget        stop tracking the specified files
   revert        change the specified files to match a commit
  
  Commit changes and modify commits:
  
   commit        save all pending changes or specified files in a new commit
  
  Rearrange commits:
  
   graft         copy commits from a different location
  
  Undo changes:
  
   uncommit      uncommit part or all of the current commit
  
  Other commands:
  
   config        show config settings
   grep          search for a pattern in tracked files in the working directory
  
  Additional help topics:
  
   filesets      specifying files by their characteristics
   glossary      common terms
   patterns      specifying files by file name pattern
   revisions     specifying commits
   templating    customizing output with templates
  *** runcommand id --quiet
  000000000000
  *** runcommand id
  000000000000 tip
  *** runcommand id --config ui.quiet=True
  000000000000
  *** runcommand id
  000000000000 tip
  *** runcommand id -runknown
  abort: unknown revision 'unknown'!
   [255]

  >>> from hgclient import check, readchannel
  >>> @check
  ... def inputeof(server):
  ...     readchannel(server)
  ...     server.stdin.write('runcommand\n')
  ...     # close stdin while server is waiting for input
  ...     server.stdin.close()
  ... 
  ...     # server exits with 1 if the pipe closed while reading the command
  ...     print('server exit code =', server.wait())
  server exit code = 1

  >>> from hgclient import check, readchannel, runcommand, stringio
  >>> @check
  ... def serverinput(server):
  ...     readchannel(server)
  ... 
  ...     patch = """
  ... # HG changeset patch
  ... # User test
  ... # Date 0 0
  ... # Node ID c103a3dec114d882c98382d684d8af798d09d857
  ... # Parent  0000000000000000000000000000000000000000
  ... 1
  ... 
  ... diff -r 000000000000 -r c103a3dec114 a
  ... --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  ... +++ b/a	Thu Jan 01 00:00:00 1970 +0000
  ... @@ -0,0 +1,1 @@
  ... +1
  ... """
  ... 
  ...     runcommand(server, ['import', '-'], input=stringio(patch))
  ...     runcommand(server, ['log'])
  *** runcommand import -
  applying patch from stdin
  *** runcommand log
  changeset:   0:eff892de26ec
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1
  

check strict parsing of early options:

  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> os.environ['HGPLAIN'] = '+strictflags'
  >>> @check
  ... def cwd(server):
  ...     readchannel(server)
  ...     runcommand(server, ['log', '-b', '--config=alias.log=!echo pwned',
  ...                         'default'])
  *** runcommand log -b --config=alias.log=!echo pwned default
  abort: unknown revision '--config=alias.log=!echo pwned'!
   [255]

check that "histedit --commands=-" can read rules from the input channel:

  >>> import cStringIO
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def serverinput(server):
  ...     readchannel(server)
  ...     rules = 'pick eff892de26ec\n'
  ...     runcommand(server, ['histedit', '0', '--commands=-',
  ...                         '--config', 'extensions.histedit='],
  ...                input=cStringIO.StringIO(rules))
  *** runcommand histedit 0 --commands=- --config extensions.histedit=

check that --cwd doesn't persist between requests:

  $ mkdir foo
  $ touch foo/bar
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def cwd(server):
  ...     readchannel(server)
  ...     runcommand(server, ['--cwd', 'foo', 'st', 'bar'])
  ...     runcommand(server, ['st', 'foo/bar'])
  *** runcommand --cwd foo st bar
  ? bar
  *** runcommand st foo/bar
  ? foo/bar

  $ rm foo/bar


check that local configs for the cached repo aren't inherited when -R is used:

  $ cat <<EOF >> .hg/hgrc
  > [ui]
  > foo = bar
  > EOF

  >>> from hgclient import check, readchannel, runcommand, sep
  >>> @check
  ... def localhgrc(server):
  ...     readchannel(server)
  ... 
  ...     # the cached repo local hgrc contains ui.foo=bar, so showconfig should
  ...     # show it
  ...     runcommand(server, ['showconfig'], outfilter=sep)
  ... 
  ...     # but not for this repo
  ...     runcommand(server, ['init', 'foo'])
  ...     runcommand(server, ['-R', 'foo', 'showconfig', 'ui', 'defaults'])
  *** runcommand showconfig
  bundle.mainreporoot=$TESTTMP/repo
  devel.all-warnings=true
  devel.default-date=0 0
  extensions.fsmonitor= (fsmonitor !)
  fsmonitor.detectrace=1 (fsmonitor !)
  ui.slash=True
  ui.interactive=False
  ui.mergemarkers=detailed
  ui.usehttp2=true (?)
  ui.foo=bar
  ui.nontty=true
  web.address=localhost
  web\.ipv6=(?:True|False) (re)
  *** runcommand init foo
  *** runcommand -R foo showconfig ui defaults
  ui.slash=True
  ui.interactive=False
  ui.mergemarkers=detailed
  ui.usehttp2=true (?)
  ui.nontty=true

  $ rm -R foo

#if windows
  $ PYTHONPATH="$TESTTMP/repo;$PYTHONPATH"
#else
  $ PYTHONPATH="$TESTTMP/repo:$PYTHONPATH"
#endif

  $ cat <<EOF > hook.py
  > from __future__ import print_function
  > import sys
  > def hook(**args):
  >     print('hook talking')
  >     print('now try to read something: %r' % sys.stdin.read())
  > EOF

  >>> from hgclient import check, readchannel, runcommand, stringio
  >>> @check
  ... def hookoutput(server):
  ...     readchannel(server)
  ...     runcommand(server, ['--config',
  ...                         'hooks.pre-identify=python:hook.hook',
  ...                         'id'],
  ...                input=stringio('some input'))
  *** runcommand --config hooks.pre-identify=python:hook.hook id
  eff892de26ec tip

Clean hook cached version
  $ rm hook.py*
  $ rm -Rf __pycache__

  $ echo a >> a
  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def outsidechanges(server):
  ...     readchannel(server)
  ...     runcommand(server, ['status'])
  ...     os.system('hg ci -Am2')
  ...     runcommand(server, ['tip'])
  ...     runcommand(server, ['status'])
  *** runcommand status
  M a
  *** runcommand tip
  changeset:   1:d3a0a68be6de
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     2
  
  *** runcommand status

  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def bookmarks(server):
  ...     readchannel(server)
  ...     runcommand(server, ['bookmarks'])
  ... 
  ...     # changes .hg/bookmarks
  ...     os.system('hg bookmark -i bm1')
  ...     os.system('hg bookmark -i bm2')
  ...     runcommand(server, ['bookmarks'])
  ... 
  ...     # changes .hg/bookmarks.current
  ...     os.system('hg upd bm1 -q')
  ...     runcommand(server, ['bookmarks'])
  ... 
  ...     runcommand(server, ['bookmarks', 'bm3'])
  ...     f = open('a', 'ab')
  ...     f.write('a\n')
  ...     f.close()
  ...     runcommand(server, ['commit', '-Amm'])
  ...     runcommand(server, ['bookmarks'])
  ...     print('')
  *** runcommand bookmarks
  no bookmarks set
  *** runcommand bookmarks
     bm1                       1:d3a0a68be6de
     bm2                       1:d3a0a68be6de
  *** runcommand bookmarks
   * bm1                       1:d3a0a68be6de
     bm2                       1:d3a0a68be6de
  *** runcommand bookmarks bm3
  *** runcommand commit -Amm
  *** runcommand bookmarks
     bm1                       1:d3a0a68be6de
     bm2                       1:d3a0a68be6de
   * bm3                       2:aef17e88f5f0
  

  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def tagscache(server):
  ...     readchannel(server)
  ...     runcommand(server, ['id', '-t', '-r', '0'])
  ...     os.system('hg tag -r 0 foo')
  ...     runcommand(server, ['id', '-t', '-r', '0'])
  *** runcommand id -t -r 0
  
  *** runcommand id -t -r 0
  foo

  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def setphase(server):
  ...     readchannel(server)
  ...     runcommand(server, ['phase', '-r', '.'])
  ...     os.system('hg phase -r . -p')
  ...     runcommand(server, ['phase', '-r', '.'])
  *** runcommand phase -r .
  3: draft
  *** runcommand phase -r .
  3: public

  $ echo a >> a
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def rollback(server):
  ...     readchannel(server)
  ...     runcommand(server, ['phase', '-r', '.', '-p'])
  ...     runcommand(server, ['commit', '-Am.'])
  ...     runcommand(server, ['rollback'])
  ...     runcommand(server, ['phase', '-r', '.'])
  ...     print('')
  *** runcommand phase -r . -p
  no phases changed
  *** runcommand commit -Am.
  *** runcommand rollback
  repository tip rolled back to revision 3 (undo commit)
  working directory now based on revision 3
  *** runcommand phase -r .
  3: public
  

  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def branch(server):
  ...     readchannel(server)
  ...     runcommand(server, ['branch'])
  ...     os.system('hg branch foo')
  ...     runcommand(server, ['branch'])
  ...     os.system('hg branch default')
  *** runcommand branch
  default
  marked working directory as branch foo
  (branches are permanent and global, did you want a bookmark?)
  *** runcommand branch
  foo
  marked working directory as branch default
  (branches are permanent and global, did you want a bookmark?)

  $ touch .hgignore
  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def hgignore(server):
  ...     readchannel(server)
  ...     runcommand(server, ['commit', '-Am.'])
  ...     f = open('ignored-file', 'ab')
  ...     f.write('')
  ...     f.close()
  ...     f = open('.hgignore', 'ab')
  ...     f.write('ignored-file')
  ...     f.close()
  ...     runcommand(server, ['status', '-i', '-u'])
  ...     print('')
  *** runcommand commit -Am.
  adding .hgignore
  *** runcommand status -i -u
  I ignored-file
  

cache of non-public revisions should be invalidated on repository change
(issue4855):

  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def phasesetscacheaftercommit(server):
  ...     readchannel(server)
  ...     # load _phasecache._phaserevs and _phasesets
  ...     runcommand(server, ['log', '-qr', 'draft()'])
  ...     # create draft commits by another process
  ...     for i in xrange(5, 7):
  ...         f = open('a', 'ab')
  ...         f.seek(0, os.SEEK_END)
  ...         f.write('a\n')
  ...         f.close()
  ...         os.system('hg commit -Aqm%d' % i)
  ...     # new commits should be listed as draft revisions
  ...     runcommand(server, ['log', '-qr', 'draft()'])
  ...     print('')
  *** runcommand log -qr draft()
  4:7966c8e3734d
  *** runcommand log -qr draft()
  4:7966c8e3734d
  5:41f6602d1c4f
  6:10501e202c35
  

  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def phasesetscacheafterstrip(server):
  ...     readchannel(server)
  ...     # load _phasecache._phaserevs and _phasesets
  ...     runcommand(server, ['log', '-qr', 'draft()'])
  ...     # strip cached revisions by another process
  ...     os.system('hg --config extensions.strip= strip -q 5')
  ...     # shouldn't abort by "unknown revision '6'"
  ...     runcommand(server, ['log', '-qr', 'draft()'])
  ...     print('')
  *** runcommand log -qr draft()
  4:7966c8e3734d
  5:41f6602d1c4f
  6:10501e202c35
  *** runcommand log -qr draft()
  4:7966c8e3734d
  

cache of phase roots should be invalidated on strip (issue3827):

  >>> import os
  >>> from hgclient import check, readchannel, runcommand, sep
  >>> @check
  ... def phasecacheafterstrip(server):
  ...     readchannel(server)
  ... 
  ...     # create new head, 5:731265503d86
  ...     runcommand(server, ['update', '-C', '0'])
  ...     f = open('a', 'ab')
  ...     f.write('a\n')
  ...     f.close()
  ...     runcommand(server, ['commit', '-Am.', 'a'])
  ...     runcommand(server, ['log', '-Gq'])
  ... 
  ...     # make it public; draft marker moves to 4:7966c8e3734d
  ...     runcommand(server, ['phase', '-p', '.'])
  ...     # load _phasecache.phaseroots
  ...     runcommand(server, ['phase', '.'], outfilter=sep)
  ... 
  ...     # strip 1::4 outside server
  ...     os.system('hg -q --config extensions.strip= strip 1')
  ... 
  ...     # shouldn't raise "7966c8e3734d: no node!"
  ...     runcommand(server, ['branches'])
  *** runcommand update -C 0
  1 files updated, 0 files merged, 2 files removed, 0 files unresolved
  (leaving bookmark bm3)
  *** runcommand commit -Am. a
  *** runcommand log -Gq
  @  5:731265503d86
  |
  | o  4:7966c8e3734d
  | |
  | o  3:b9b85890c400
  | |
  | o  2:aef17e88f5f0
  | |
  | o  1:d3a0a68be6de
  |/
  o  0:eff892de26ec
  
  *** runcommand phase -p .
  *** runcommand phase .
  5: public
  *** runcommand branches
  default                        1:731265503d86

in-memory cache must be reloaded if transaction is aborted. otherwise
changelog and manifest would have invalid node:

  $ echo a >> a
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def txabort(server):
  ...     readchannel(server)
  ...     runcommand(server, ['commit', '--config', 'hooks.pretxncommit=false',
  ...                         '-mfoo'])
  ...     runcommand(server, ['verify'])
  *** runcommand commit --config hooks.pretxncommit=false -mfoo
  transaction abort!
  rollback completed
  abort: pretxncommit hook exited with status 1
   [255]
  *** runcommand verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  1 files, 2 changesets, 2 total revisions
  $ hg revert --no-backup -aq

  $ cat >> .hg/hgrc << EOF
  > [experimental]
  > evolution.createmarkers=True
  > EOF

  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def obsolete(server):
  ...     readchannel(server)
  ... 
  ...     runcommand(server, ['up', 'null'])
  ...     runcommand(server, ['phase', '-df', 'tip'])
  ...     cmd = 'hg debugobsolete `hg log -r tip --template {node}`'
  ...     if os.name == 'nt':
  ...         cmd = 'sh -c "%s"' % cmd # run in sh, not cmd.exe
  ...     os.system(cmd)
  ...     runcommand(server, ['log', '--hidden'])
  ...     runcommand(server, ['log'])
  *** runcommand up null
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  *** runcommand phase -df tip
  obsoleted 1 changesets
  *** runcommand log --hidden
  changeset:   1:731265503d86
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  obsolete:    pruned
  summary:     .
  
  changeset:   0:eff892de26ec
  bookmark:    bm1
  bookmark:    bm2
  bookmark:    bm3
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1
  
  *** runcommand log
  changeset:   0:eff892de26ec
  bookmark:    bm1
  bookmark:    bm2
  bookmark:    bm3
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1
  

  $ cat <<EOF > dbgui.py
  > import os
  > import sys
  > from edenscm.mercurial import commands, registrar
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > @command(b"debuggetpass", norepo=True)
  > def debuggetpass(ui):
  >     ui.write("%s\\n" % ui.getpass())
  > @command(b"debugprompt", norepo=True)
  > def debugprompt(ui):
  >     ui.write("%s\\n" % ui.prompt("prompt:"))
  > @command(b"debugreadstdin", norepo=True)
  > def debugreadstdin(ui):
  >     ui.write("read: %r\n" % sys.stdin.read(1))
  > @command(b"debugwritestdout", norepo=True)
  > def debugwritestdout(ui):
  >     os.write(1, "low-level stdout fd and\n")
  >     sys.stdout.write("stdout should be redirected to /dev/null\n")
  >     sys.stdout.flush()
  > EOF
  $ cat <<EOF >> .hg/hgrc
  > [extensions]
  > dbgui = dbgui.py
  > EOF

  >>> from hgclient import check, readchannel, runcommand, stringio
  >>> @check
  ... def getpass(server):
  ...     readchannel(server)
  ...     runcommand(server, ['debuggetpass', '--config',
  ...                         'ui.interactive=True'],
  ...                input=stringio('1234\n'))
  ...     runcommand(server, ['debuggetpass', '--config',
  ...                         'ui.interactive=True'],
  ...                input=stringio('\n'))
  ...     runcommand(server, ['debuggetpass', '--config',
  ...                         'ui.interactive=True'],
  ...                input=stringio(''))
  ...     runcommand(server, ['debugprompt', '--config',
  ...                         'ui.interactive=True'],
  ...                input=stringio('5678\n'))
  ...     runcommand(server, ['debugreadstdin'])
  ...     runcommand(server, ['debugwritestdout'])
  *** runcommand debuggetpass --config ui.interactive=True
  password: 1234
  *** runcommand debuggetpass --config ui.interactive=True
  password: 
  *** runcommand debuggetpass --config ui.interactive=True
  password: abort: response expected
   [255]
  *** runcommand debugprompt --config ui.interactive=True
  prompt: 5678
  *** runcommand debugreadstdin
  read: ''
  *** runcommand debugwritestdout


run commandserver in commandserver, which is silly but should work:

  >>> from __future__ import print_function
  >>> from hgclient import check, readchannel, runcommand, stringio
  >>> @check
  ... def nested(server):
  ...     print('%c, %r' % readchannel(server))
  ...     class nestedserver(object):
  ...         stdin = stringio('getencoding\n')
  ...         stdout = stringio()
  ...     runcommand(server, ['serve', '--cmdserver', 'pipe'],
  ...                output=nestedserver.stdout, input=nestedserver.stdin)
  ...     nestedserver.stdout.seek(0)
  ...     print('%c, %r' % readchannel(nestedserver))  # hello
  ...     print('%c, %r' % readchannel(nestedserver))  # getencoding
  o, 'capabilities: getencoding runcommand\nencoding: *\npid: *' (glob)
  *** runcommand serve --cmdserver pipe
  o, 'capabilities: getencoding runcommand\nencoding: *\npid: *' (glob)
  r, '*' (glob)


start without repository:

  $ cd ..

  >>> from __future__ import print_function
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def hellomessage(server):
  ...     ch, data = readchannel(server)
  ...     print('%c, %r' % (ch, data))
  ...     # run an arbitrary command to make sure the next thing the server
  ...     # sends isn't part of the hello message
  ...     runcommand(server, ['id'])
  o, 'capabilities: getencoding runcommand\nencoding: *\npid: *' (glob)
  *** runcommand id
  abort: there is no Mercurial repository here (.hg not found)
   [255]

  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def startwithoutrepo(server):
  ...     readchannel(server)
  ...     runcommand(server, ['init', 'repo2'])
  ...     runcommand(server, ['id', '-R', 'repo2'])
  *** runcommand init repo2
  *** runcommand id -R repo2
  000000000000 tip


don't fall back to cwd if invalid -R path is specified (issue4805):

  $ cd repo
  $ hg serve --cmdserver pipe -R ../nonexistent
  abort: repository ../nonexistent not found!
  [255]
  $ cd ..


unix domain socket:

  $ cd repo
  $ hg update -q

#if unix-socket unix-permissions

  >>> from __future__ import print_function
  >>> from hgclient import check, readchannel, runcommand, stringio, unixserver
  >>> server = unixserver('.hg/server.sock', '.hg/server.log')
  >>> def hellomessage(conn):
  ...     ch, data = readchannel(conn)
  ...     print('%c, %r' % (ch, data))
  ...     runcommand(conn, ['id'])
  >>> check(hellomessage, server.connect)
  o, 'capabilities: getencoding runcommand\nencoding: *\npid: *' (glob)
  *** runcommand id
  eff892de26ec tip bm1/bm2/bm3
  >>> def unknowncommand(conn):
  ...     readchannel(conn)
  ...     conn.stdin.write('unknowncommand\n')
  >>> check(unknowncommand, server.connect)  # error sent to server.log
  >>> def serverinput(conn):
  ...     readchannel(conn)
  ...     patch = """
  ... # HG changeset patch
  ... # User test
  ... # Date 0 0
  ... 2
  ... 
  ... diff -r eff892de26ec -r 1ed24be7e7a0 a
  ... --- a/a
  ... +++ b/a
  ... @@ -1,1 +1,2 @@
  ...  1
  ... +2
  ... """
  ...     runcommand(conn, ['import', '-'], input=stringio(patch))
  ...     runcommand(conn, ['log', '-rtip', '-q'])
  >>> check(serverinput, server.connect)
  *** runcommand import -
  applying patch from stdin
  *** runcommand log -rtip -q
  2:1ed24be7e7a0
  >>> server.shutdown()

  $ cat .hg/server.log
  listening at .hg/server.sock
  abort: unknown command unknowncommand
  killed!
  $ rm .hg/server.log

 if server crashed before hello, traceback will be sent to 'e' channel as
 last ditch:

  $ cat <<EOF >> .hg/hgrc
  > [cmdserver]
  > log = inexistent/path.log
  > EOF
  >>> from __future__ import print_function
  >>> from hgclient import check, readchannel, unixserver
  >>> server = unixserver('.hg/server.sock', '.hg/server.log')
  >>> def earlycrash(conn):
  ...     while True:
  ...         try:
  ...             ch, data = readchannel(conn)
  ...             if not data.startswith('  '):
  ...                 print('%c, %r' % (ch, data))
  ...         except EOFError:
  ...             break
  >>> check(earlycrash, server.connect)
  e, 'Traceback (most recent call last):\n'
  e, "IOError: *" (glob)
  >>> server.shutdown()

  $ cat .hg/server.log | grep -v '^  '
  listening at .hg/server.sock
  Traceback (most recent call last):
  IOError: * (glob)
  killed!
#endif
#if no-unix-socket

  $ hg serve --cmdserver unix -a .hg/server.sock
  abort: unsupported platform
  [255]

#endif

  $ cd ..

Test that accessing to invalid changelog cache is avoided at
subsequent operations even if repo object is reused even after failure
of transaction (see 0a7610758c42 also)

"hg log" after failure of transaction is needed to detect invalid
cache in repoview: this can't detect by "hg verify" only.

Combination of "finalization" and "empty-ness of changelog" (2 x 2 =
4) are tested, because '00changelog.i' are differently changed in each
cases.

  $ cat > $TESTTMP/failafterfinalize.py <<EOF
  > # extension to abort transaction after finalization forcibly
  > from edenscm.mercurial import commands, error, extensions, lock as lockmod
  > from edenscm.mercurial import registrar
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > configtable = {}
  > configitem = registrar.configitem(configtable)
  > configitem('failafterfinalize', 'fail',
  >     default=None,
  > )
  > def fail(tr):
  >     raise error.Abort('fail after finalization')
  > def reposetup(ui, repo):
  >     class failrepo(repo.__class__):
  >         def commitctx(self, ctx, error=False):
  >             if self.ui.configbool('failafterfinalize', 'fail'):
  >                 # 'sorted()' by ASCII code on category names causes
  >                 # invoking 'fail' after finalization of changelog
  >                 # using "'cl-%i' % id(self)" as category name
  >                 self.currenttransaction().addfinalize('zzzzzzzz', fail)
  >             return super(failrepo, self).commitctx(ctx, error)
  >     repo.__class__ = failrepo
  > EOF

  $ hg init repo3
  $ cd repo3

  $ cat <<EOF >> $HGRCPATH
  > [ui]
  > logtemplate = {rev} {desc|firstline} ({files})\n
  > 
  > [extensions]
  > failafterfinalize = $TESTTMP/failafterfinalize.py
  > EOF

- test failure with "empty changelog"

  $ echo foo > foo
  $ hg add foo

(failure before finalization)

  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def abort(server):
  ...     readchannel(server)
  ...     runcommand(server, ['commit',
  ...                         '--config', 'hooks.pretxncommit=false',
  ...                         '-mfoo'])
  ...     runcommand(server, ['log'])
  ...     runcommand(server, ['verify', '-q'])
  *** runcommand commit --config hooks.pretxncommit=false -mfoo
  transaction abort!
  rollback completed
  abort: pretxncommit hook exited with status 1
   [255]
  *** runcommand log
  *** runcommand verify -q

(failure after finalization)

  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def abort(server):
  ...     readchannel(server)
  ...     runcommand(server, ['commit',
  ...                         '--config', 'failafterfinalize.fail=true',
  ...                         '-mfoo'])
  ...     runcommand(server, ['log'])
  ...     runcommand(server, ['verify', '-q'])
  *** runcommand commit --config failafterfinalize.fail=true -mfoo
  transaction abort!
  rollback completed
  abort: fail after finalization
   [255]
  *** runcommand log
  *** runcommand verify -q

- test failure with "not-empty changelog"

  $ echo bar > bar
  $ hg add bar
  $ hg commit -mbar bar

(failure before finalization)

  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def abort(server):
  ...     readchannel(server)
  ...     runcommand(server, ['commit',
  ...                         '--config', 'hooks.pretxncommit=false',
  ...                         '-mfoo', 'foo'])
  ...     runcommand(server, ['log'])
  ...     runcommand(server, ['verify', '-q'])
  *** runcommand commit --config hooks.pretxncommit=false -mfoo foo
  transaction abort!
  rollback completed
  abort: pretxncommit hook exited with status 1
   [255]
  *** runcommand log
  0 bar (bar)
  *** runcommand verify -q

(failure after finalization)

  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def abort(server):
  ...     readchannel(server)
  ...     runcommand(server, ['commit',
  ...                         '--config', 'failafterfinalize.fail=true',
  ...                         '-mfoo', 'foo'])
  ...     runcommand(server, ['log'])
  ...     runcommand(server, ['verify', '-q'])
  *** runcommand commit --config failafterfinalize.fail=true -mfoo foo
  transaction abort!
  rollback completed
  abort: fail after finalization
   [255]
  *** runcommand log
  0 bar (bar)
  *** runcommand verify -q

  $ cd ..

Test symlink traversal over cached audited paths:
-------------------------------------------------

#if symlink

set up symlink hell

  $ mkdir merge-symlink-out
  $ hg init merge-symlink
  $ cd merge-symlink
  $ touch base
  $ hg commit -qAm base
  $ ln -s ../merge-symlink-out a
  $ hg commit -qAm 'symlink a -> ../merge-symlink-out'
  $ hg up -q 0
  $ mkdir a
  $ touch a/poisoned
  $ hg commit -qAm 'file a/poisoned'
  $ hg log -G -T '{rev}: {desc}\n'
  @  2: file a/poisoned
  |
  | o  1: symlink a -> ../merge-symlink-out
  |/
  o  0: base
  

try trivial merge after update: cache of audited paths should be discarded,
and the merge should fail (issue5628)

  $ hg up -q null
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def merge(server):
  ...     readchannel(server)
  ...     # audit a/poisoned as a good path
  ...     runcommand(server, ['up', '-qC', '2'])
  ...     runcommand(server, ['up', '-qC', '1'])
  ...     # here a is a symlink, so a/poisoned is bad
  ...     runcommand(server, ['merge', '2'])
  *** runcommand up -qC 2
  *** runcommand up -qC 1
  *** runcommand merge 2
  abort: path 'a/poisoned' traverses symbolic link 'a'
   [255]
  $ ls ../merge-symlink-out

cache of repo.auditor should be discarded, so matcher would never traverse
symlinks:

  $ hg up -qC 0
  $ touch ../merge-symlink-out/poisoned
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def files(server):
  ...     readchannel(server)
  ...     runcommand(server, ['up', '-qC', '2'])
  ...     # audit a/poisoned as a good path
  ...     runcommand(server, ['files', 'a/poisoned'])
  ...     runcommand(server, ['up', '-qC', '0'])
  ...     runcommand(server, ['up', '-qC', '1'])
  ...     # here 'a' is a symlink, so a/poisoned should be warned
  ...     runcommand(server, ['files', 'a/poisoned'])
  *** runcommand up -qC 2
  *** runcommand files a/poisoned
  a/poisoned
  *** runcommand up -qC 0
  *** runcommand up -qC 1
  *** runcommand files a/poisoned
  abort: path 'a/poisoned' traverses symbolic link 'a'
   [255]

  $ cd ..

#endif
