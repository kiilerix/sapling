# remotefilelogserver.py - server logic for a remotefilelog server
#
# Copyright 2013 Facebook, Inc.
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
from __future__ import absolute_import

import errno
import json
import os
import stat
import time

from edenscm.mercurial import (
    changegroup,
    changelog,
    context,
    error,
    exchange,
    extensions,
    match,
    progress,
    sshserver,
    store,
    util,
    wireproto,
)
from edenscm.mercurial.extensions import wrapfunction
from edenscm.mercurial.hgweb import protocol as httpprotocol
from edenscm.mercurial.i18n import _
from edenscm.mercurial.node import bin, hex, nullid, nullrev

from . import constants, lz4wrapper, shallowrepo, shallowutil, wirepack


try:
    xrange(0)
except NameError:
    xrange = range

try:
    from edenscm.mercurial import streamclone

    streamclone._walkstreamfiles
    hasstreamclone = True
except Exception:
    hasstreamclone = False


onetime = False


def onetimesetup(ui):
    """Configures the wireprotocol for both clients and servers.
    """
    global onetime
    if onetime:
        return
    onetime = True

    # support file content requests
    wireproto.commands["getflogheads"] = (getflogheads, "path")
    wireproto.commands["getfiles"] = (getfiles, "")
    wireproto.commands["getfile"] = (getfile, "file node")
    wireproto.commands["getpackv1"] = (getpack, "*")

    class streamstate(object):
        match = None
        shallowremote = False
        noflatmf = False

    state = streamstate()

    def stream_out_shallow(repo, proto, other):
        includepattern = None
        excludepattern = None
        raw = other.get("includepattern")
        if raw:
            includepattern = raw.split("\0")
        raw = other.get("excludepattern")
        if raw:
            excludepattern = raw.split("\0")

        oldshallow = state.shallowremote
        oldmatch = state.match
        oldnoflatmf = state.noflatmf
        try:
            state.shallowremote = True
            state.match = match.always(repo.root, "")
            state.noflatmf = other.get("noflatmanifest") == "True"
            if includepattern or excludepattern:
                state.match = match.match(
                    repo.root, "", None, includepattern, excludepattern
                )
            streamres = wireproto.stream(repo, proto)

            # Force the first value to execute, so the file list is computed
            # within the try/finally scope
            first = next(streamres.gen)
            second = next(streamres.gen)

            def gen():
                yield first
                yield second
                for value in streamres.gen:
                    yield value

            return wireproto.streamres(gen())
        finally:
            state.shallowremote = oldshallow
            state.match = oldmatch
            state.noflatmf = oldnoflatmf

    wireproto.commands["stream_out_shallow"] = (stream_out_shallow, "*")

    # don't clone filelogs to shallow clients
    def _walkstreamfiles(orig, repo):
        if state.shallowremote:
            # if we are shallow ourselves, stream our local commits
            if shallowrepo.requirement in repo.requirements:
                striplen = len(repo.store.path) + 1
                readdir = repo.store.rawvfs.readdir
                visit = [os.path.join(repo.store.path, "data")]
                while visit:
                    p = visit.pop()
                    for f, kind, st in readdir(p, stat=True):
                        fp = p + "/" + f
                        if kind == stat.S_IFREG:
                            if not fp.endswith(".i") and not fp.endswith(".d"):
                                n = util.pconvert(fp[striplen:])
                                yield (store.decodedir(n), n, st.st_size)
                        if kind == stat.S_IFDIR:
                            visit.append(fp)

            shallowtrees = repo.ui.configbool("remotefilelog", "shallowtrees", False)
            if "treemanifest" in repo.requirements and not shallowtrees:
                for (u, e, s) in repo.store.datafiles():
                    if u.startswith("meta/") and (u.endswith(".i") or u.endswith(".d")):
                        yield (u, e, s)

            # Return .d and .i files that do not match the shallow pattern
            match = state.match
            if match and not match.always():
                for (u, e, s) in repo.store.datafiles():
                    f = u[5:-2]  # trim data/...  and .i/.d
                    if not state.match(f):
                        yield (u, e, s)

            for x in repo.store.topfiles():
                if shallowtrees and x[0][:15] == "00manifesttree.":
                    continue
                if state.noflatmf and x[0][:11] == "00manifest.":
                    continue
                yield x

        elif shallowrepo.requirement in repo.requirements:
            # don't allow cloning from a shallow repo to a full repo
            # since it would require fetching every version of every
            # file in order to create the revlogs.
            raise error.Abort(_("Cannot clone from a shallow repo " "to a full repo."))
        else:
            for x in orig(repo):
                yield x

    # This function moved in Mercurial 3.5 and 3.6
    if hasstreamclone:
        wrapfunction(streamclone, "_walkstreamfiles", _walkstreamfiles)
    elif util.safehasattr(wireproto, "_walkstreamfiles"):
        wrapfunction(wireproto, "_walkstreamfiles", _walkstreamfiles)
    else:
        wrapfunction(exchange, "_walkstreamfiles", _walkstreamfiles)

    # We no longer use getbundle_shallow commands, but we must still
    # support it for migration purposes
    def getbundleshallow(repo, proto, others):
        bundlecaps = others.get("bundlecaps", "")
        bundlecaps = set(bundlecaps.split(","))
        bundlecaps.add("remotefilelog")
        others["bundlecaps"] = ",".join(bundlecaps)

        return wireproto.commands["getbundle"][0](repo, proto, others)

    wireproto.commands["getbundle_shallow"] = (getbundleshallow, "*")

    # expose remotefilelog capabilities
    def _capabilities(orig, repo, proto):
        caps = orig(repo, proto)
        if shallowrepo.requirement in repo.requirements or ui.configbool(
            "remotefilelog", "server"
        ):
            if isinstance(proto, sshserver.sshserver):
                # legacy getfiles method which only works over ssh
                caps.append(shallowrepo.requirement)
            caps.append("getflogheads")
            caps.append("getfile")
        return caps

    if util.safehasattr(wireproto, "_capabilities"):
        wrapfunction(wireproto, "_capabilities", _capabilities)
    else:
        wrapfunction(wireproto, "capabilities", _capabilities)

    def _adjustlinkrev(orig, self, *args, **kwargs):
        # When generating file blobs, taking the real path is too slow on large
        # repos, so force it to just return the linkrev directly.
        repo = self._repo
        if util.safehasattr(repo, "forcelinkrev") and repo.forcelinkrev:
            return self._filelog.linkrev(self._filelog.rev(self._filenode))
        return orig(self, *args, **kwargs)

    wrapfunction(context.basefilectx, "_adjustlinkrev", _adjustlinkrev)

    def _iscmd(orig, cmd):
        if cmd == "getfiles":
            return False
        return orig(cmd)

    wrapfunction(httpprotocol, "iscmd", _iscmd)


def _loadfileblob(repo, cachepath, path, node):
    filecachepath = os.path.join(cachepath, path, hex(node))
    if not os.path.exists(filecachepath) or os.path.getsize(filecachepath) == 0:
        filectx = repo.filectx(path, fileid=node)
        if filectx.node() == nullid:
            repo.changelog = changelog.changelog(repo.svfs)
            filectx = repo.filectx(path, fileid=node)

        text = createfileblob(filectx)
        text = lz4wrapper.lz4compresshc(text)

        # everything should be user & group read/writable
        oldumask = os.umask(0o002)
        try:
            dirname = os.path.dirname(filecachepath)
            if not os.path.exists(dirname):
                try:
                    os.makedirs(dirname)
                except OSError as ex:
                    if ex.errno != errno.EEXIST:
                        raise

            f = None
            try:
                f = util.atomictempfile(filecachepath, "w")
                f.write(text)
            except (IOError, OSError):
                # Don't abort if the user only has permission to read,
                # and not write.
                pass
            finally:
                if f:
                    f.close()
        finally:
            os.umask(oldumask)
    else:
        with util.posixfile(filecachepath, "r") as f:
            text = f.read()
    return text


def getflogheads(repo, proto, path):
    """A server api for requesting a filelog's heads
    """
    flog = repo.file(path)
    heads = flog.heads()
    return "\n".join((hex(head) for head in heads if head != nullid))


def getfile(repo, proto, file, node):
    """A server api for requesting a particular version of a file. Can be used
    in batches to request many files at once. The return protocol is:
    <errorcode>\0<data/errormsg> where <errorcode> is 0 for success or
    non-zero for an error.

    data is a compressed blob with revlog flag and ancestors information. See
    createfileblob for its content.
    """
    if shallowrepo.requirement in repo.requirements:
        return "1\0" + _("cannot fetch remote files from shallow repo")
    cachepath = repo.ui.config("remotefilelog", "servercachepath")
    if not cachepath:
        cachepath = os.path.join(repo.path, "remotefilelogcache")
    node = bin(node.strip())
    if node == nullid:
        return "0\0"
    return "0\0" + _loadfileblob(repo, cachepath, file, node)


def getfiles(repo, proto):
    """A server api for requesting particular versions of particular files.
    """
    if shallowrepo.requirement in repo.requirements:
        raise error.Abort(_("cannot fetch remote files from shallow repo"))
    if not isinstance(proto, sshserver.sshserver):
        raise error.Abort(_("cannot fetch remote files over non-ssh protocol"))

    def streamer():
        fin = proto.fin

        cachepath = repo.ui.config("remotefilelog", "servercachepath")
        if not cachepath:
            cachepath = os.path.join(repo.path, "remotefilelogcache")

        args = []
        responselen = 0
        start_time = time.time()

        while True:
            request = fin.readline()[:-1]
            if not request:
                break

            hexnode = request[:40]
            node = bin(hexnode)
            if node == nullid:
                yield "0\n"
                continue

            path = request[40:]

            args.append([hexnode, path])

            text = _loadfileblob(repo, cachepath, path, node)

            response = "%d\n%s" % (len(text), text)
            responselen += len(response)
            yield response

            # it would be better to only flush after processing a whole batch
            # but currently we don't know if there are more requests coming
            proto.fout.flush()

        if repo.ui.configbool("wireproto", "loggetfiles"):
            try:
                serializedargs = json.dumps(args)
            except Exception:
                serializedargs = "Failed to serialize arguments"

            kwargs = {}
            try:
                clienttelemetry = extensions.find("clienttelemetry")
                kwargs = clienttelemetry.getclienttelemetry(repo)
            except KeyError:
                pass
            reponame = repo.ui.config("common", "reponame", "unknown")
            kwargs["reponame"] = reponame
            repo.ui.log(
                "wireproto_requests",
                "",
                command="getfiles",
                args=serializedargs,
                responselen=responselen,
                duration=int((time.time() - start_time) * 1000),
                **kwargs
            )

    return wireproto.streamres(streamer())


def createfileblob(filectx):
    """
    format:
        v0:
            str(len(rawtext)) + '\0' + rawtext + ancestortext
        v1:
            'v1' + '\n' + metalist + '\0' + rawtext + ancestortext
            metalist := metalist + '\n' + meta | meta
            meta := sizemeta | flagmeta
            sizemeta := METAKEYSIZE + str(len(rawtext))
            flagmeta := METAKEYFLAG + str(flag)

            note: sizemeta must exist. METAKEYFLAG and METAKEYSIZE must have a
            length of 1.
    """
    flog = filectx.filelog()
    frev = filectx.filerev()
    revlogflags = flog.flags(frev)
    if revlogflags == 0:
        # normal files
        text = filectx.data()
    else:
        # lfs, read raw revision data
        text = flog.revision(frev, raw=True)

    repo = filectx._repo

    ancestors = [filectx]

    try:
        repo.forcelinkrev = True
        ancestors.extend([f for f in filectx.ancestors()])

        ancestortext = ""
        for ancestorctx in ancestors:
            parents = ancestorctx.parents()
            p1 = nullid
            p2 = nullid
            if len(parents) > 0:
                p1 = parents[0].filenode()
            if len(parents) > 1:
                p2 = parents[1].filenode()

            copyname = ""
            rename = ancestorctx.renamed()
            if rename:
                copyname = rename[0]
            linknode = ancestorctx.node()
            ancestortext += "%s%s%s%s%s\0" % (
                ancestorctx.filenode(),
                p1,
                p2,
                linknode,
                copyname,
            )
    finally:
        repo.forcelinkrev = False

    header = shallowutil.buildfileblobheader(len(text), revlogflags)

    return "%s\0%s%s" % (header, text, ancestortext)


def gcserver(ui, repo):
    if not repo.ui.configbool("remotefilelog", "server"):
        return

    neededfiles = set()
    heads = repo.revs("heads(tip~25000:) - null")

    cachepath = repo.localvfs.join("remotefilelogcache")
    for head in heads:
        mf = repo[head].manifest()
        for filename, filenode in mf.iteritems():
            filecachepath = os.path.join(cachepath, filename, hex(filenode))
            neededfiles.add(filecachepath)

    # delete unneeded older files
    days = repo.ui.configint("remotefilelog", "serverexpiration", 30)
    expiration = time.time() - (days * 24 * 60 * 60)

    with progress.bar(ui, _("removing old server cache"), "files") as prog:
        for root, dirs, files in os.walk(cachepath):
            for file in files:
                filepath = os.path.join(root, file)
                prog.value += 1
                if filepath in neededfiles:
                    continue

                stat = os.stat(filepath)
                if stat.st_mtime < expiration:
                    os.remove(filepath)


def getpack(repo, proto, args):
    """A server api for requesting a pack of file information.
    """
    if shallowrepo.requirement in repo.requirements:
        raise error.Abort(_("cannot fetch remote files from shallow repo"))
    if not isinstance(proto, sshserver.sshserver):
        raise error.Abort(_("cannot fetch remote files over non-ssh protocol"))

    def streamer():
        """Request format:

        [<filerequest>,...]\0\0
        filerequest = <filename len: 2 byte><filename><count: 4 byte>
                      [<node: 20 byte>,...]

        Response format:
        [<fileresponse>,...]<10 null bytes>
        fileresponse = <filename len: 2 byte><filename><history><deltas>
        history = <count: 4 byte>[<history entry>,...]
        historyentry = <node: 20 byte><p1: 20 byte><p2: 20 byte>
                       <linknode: 20 byte><copyfrom len: 2 byte><copyfrom>
        deltas = <count: 4 byte>[<delta entry>,...]
        deltaentry = <node: 20 byte><deltabase: 20 byte>
                     <delta len: 8 byte><delta>
        """
        files = _receivepackrequest(proto.fin)

        # Sort the files by name, so we provide deterministic results
        for filename, nodes in sorted(files.iteritems()):
            fl = repo.file(filename)

            # Compute history
            history = []
            for rev in fl.ancestors(list(fl.rev(n) for n in nodes), inclusive=True):
                x, x, x, x, linkrev, p1, p2, node = fl.index[rev]
                copyfrom = ""
                p1node = fl.node(p1)
                p2node = fl.node(p2)
                linknode = repo.changelog.node(linkrev)
                if p1node == nullid:
                    copydata = fl.renamed(node)
                    if copydata:
                        copyfrom, copynode = copydata
                        p1node = copynode

                history.append((node, p1node, p2node, linknode, copyfrom))

            # Scan and send deltas
            chain = _getdeltachain(fl, nodes, -1)

            for chunk in wirepack.sendpackpart(filename, history, chain):
                yield chunk

        yield wirepack.closepart()
        proto.fout.flush()

    return wireproto.streamres(streamer())


def _receivepackrequest(stream):
    files = {}
    while True:
        filenamelen = shallowutil.readunpack(stream, constants.FILENAMESTRUCT)[0]
        if filenamelen == 0:
            break

        filename = shallowutil.readexactly(stream, filenamelen)

        nodecount = shallowutil.readunpack(stream, constants.PACKREQUESTCOUNTSTRUCT)[0]

        # Read N nodes
        nodes = shallowutil.readexactly(stream, constants.NODESIZE * nodecount)
        nodes = set(
            nodes[i : i + constants.NODESIZE]
            for i in xrange(0, len(nodes), constants.NODESIZE)
        )

        files[filename] = nodes

    return files


def _getdeltachain(fl, nodes, stophint):
    """Produces a chain of deltas that includes each of the given nodes.

    `stophint` - The changeset rev number to stop at. If it's set to >= 0, we
    will return not only the deltas for the requested nodes, but also all
    necessary deltas in their delta chains, as long as the deltas have link revs
    >= the stophint. This allows us to return an approximately minimal delta
    chain when the user performs a pull. If `stophint` is set to -1, all nodes
    will return full texts.  """
    chain = []

    seen = set()
    for node in nodes:
        startrev = fl.rev(node)
        cur = startrev
        while True:
            if cur in seen:
                break
            start, length, size, base, linkrev, p1, p2, node = fl.index[cur]
            if linkrev < stophint and cur != startrev:
                break

            # Return a full text if:
            # - the caller requested it (via stophint == -1)
            # - the revlog chain has ended (via base==null or base==node)
            # - p1 is null. In some situations this can mean it's a copy, so
            # we need to use fl.read() to remove the copymetadata.
            if stophint == -1 or base == nullrev or base == cur or p1 == nullrev:
                delta = fl.read(cur)
                base = nullrev
            else:
                delta = fl._chunk(cur)

            basenode = fl.node(base)
            chain.append((node, basenode, delta))
            seen.add(cur)

            if base == nullrev:
                break
            cur = base

    chain.reverse()
    return chain
