/**
 * FUSE filesystem for mounting Git repositories.
 *
 * Features:
 * - /index/ - Read-write access to the Git staging area
 * - /commits/<sha>/ - Read-only access to commits by hash
 * - /refs/<refname>/ - Read-only access to refs (branches, tags)
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 */

import core.stdc.errno;
import core.sys.posix.fcntl;
import core.sys.posix.sys.stat;
import core.sys.posix.unistd;
import core.time : MonoTime;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.internal.cstring;
import std.path;
import std.stdio : stderr;
import std.string;
import std.typecons : Nullable;

import c.fuse.fuse;

import ae.sys.git;
import ae.utils.funopt;
import ae.utils.main;

pragma(lib, "fuse");


//==============================================================================
// Globals
//==============================================================================

__gshared
{
    Git repo;
}

//==============================================================================
// Index entry cache (refreshed from git ls-files on each operation)
//==============================================================================

struct IndexEntry
{
    uint mode;
    Git.OID oid;
    string path;
}

/// Get all index entries using git ls-files
IndexEntry[] getIndexEntries()
{
    IndexEntry[] entries;

    // Use -z for null-separated output (safe for paths with special chars)
    auto output = repo.query("ls-files", "--stage", "-z");

    foreach (line; output.split('\0'))
    {
        if (line.length == 0) continue;

        // Format: <mode> <hash> <stage>\t<path>
        auto tabPos = line.indexOf('\t');
        if (tabPos < 0) continue;

        auto meta = line[0 .. tabPos];
        auto path = line[tabPos + 1 .. $];

        auto parts = meta.split(' ');
        if (parts.length < 3) continue;

        IndexEntry entry;
        entry.mode = parts[0].to!uint(8);
        entry.oid = Git.OID(parts[1]);
        entry.path = path;
        entries ~= entry;
    }

    return entries;
}

/// Find an index entry by path
Nullable!IndexEntry findIndexEntry(string path)
{
    foreach (entry; getIndexEntries())
        if (entry.path == path)
            return Nullable!IndexEntry(entry);
    return Nullable!IndexEntry.init;
}


//==============================================================================
// Path parsing
//==============================================================================

/// Parsed FUSE path
struct FusePath
{
    enum Type { invalid, root, indexRoot, indexFile, indexDir, commitsRoot, commitDir, commitFile, refsRoot, refDir, refFile }
    Type type;

    // For index paths
    string indexPath; // path within index (without leading "index/")

    // For commit/ref paths
    string commitOrRef; // commit SHA or ref name
    string treePath;    // path within tree

    static FusePath parse(const char* c_path)
    {
        FusePath result;
        auto path = c_path.fromStringz.idup;

        if (!path.startsWith("/"))
        {
            result.type = Type.invalid;
            return result;
        }

        path = path[1 .. $]; // strip leading /

        if (path.length == 0)
        {
            result.type = Type.root;
            return result;
        }

        auto parts = path.split("/");

        if (parts[0] == "index")
        {
            if (parts.length == 1)
            {
                result.type = Type.indexRoot;
                return result;
            }

            result.indexPath = parts[1 .. $].join("/");

            // Check if it's a file or directory in the index
            if (isIndexFile(result.indexPath))
                result.type = Type.indexFile;
            else if (isIndexDir(result.indexPath))
                result.type = Type.indexDir;
            else
                result.type = Type.invalid;

            return result;
        }

        if (parts[0] == "commits")
        {
            if (parts.length == 1)
            {
                result.type = Type.commitsRoot;
                return result;
            }

            result.commitOrRef = parts[1];
            result.treePath = parts.length > 2 ? parts[2 .. $].join("/") : "";

            if (result.treePath.length == 0)
                result.type = Type.commitDir;
            else
                result.type = Type.commitFile; // will be refined later

            return result;
        }

        if (parts[0] == "refs")
        {
            if (parts.length == 1)
            {
                result.type = Type.refsRoot;
                return result;
            }

            // refs can have slashes (e.g., refs/heads/master)
            // We need to find where the ref name ends and tree path begins
            result.commitOrRef = parts[1 .. $].join("/");
            result.treePath = "";
            result.type = Type.refDir;

            return result;
        }

        result.type = Type.invalid;
        return result;
    }
}

/// Check if a path exists as a file in the index
bool isIndexFile(string path)
{
    return !findIndexEntry(path).isNull;
}

/// Check if a path exists as a directory in the index
bool isIndexDir(string path)
{
    auto prefix = path.length > 0 ? path ~ "/" : "";
    foreach (entry; getIndexEntries())
        if (entry.path.startsWith(prefix))
            return true;
    return false;
}

/// Get index entries in a directory
string[] getIndexDirEntries(string dirPath)
{
    auto prefix = dirPath.length > 0 ? dirPath ~ "/" : "";
    bool[string] names;

    foreach (entry; getIndexEntries())
    {
        if (entry.path.startsWith(prefix))
        {
            auto rest = entry.path[prefix.length .. $];
            auto slashPos = rest.indexOf('/');
            if (slashPos >= 0)
                names[rest[0 .. slashPos]] = true;
            else
                names[rest] = true;
        }
    }

    return names.keys.sort.array;
}


//==============================================================================
// FUSE helpers
//==============================================================================

int fuseWrap(scope int delegate() dg) nothrow
{
    try
        return dg();
    catch (ErrnoException e)
    {
        debug stderr.writeln(e).assumeWontThrow;
        return -e.errno;
    }
    catch (FileException e)
    {
        debug stderr.writeln(e).assumeWontThrow;
        return -e.errno;
    }
    catch (Exception e)
    {
        debug stderr.writeln(e).assumeWontThrow;
        return -EIO;
    }
}

int fuseWrap(scope void delegate() dg) nothrow
{
    return fuseWrap({ dg(); return 0; });
}


//==============================================================================
// Index operations (using git plumbing commands)
//==============================================================================

/// Read blob content by OID
immutable(ubyte)[] readBlob(Git.OID oid)
{
    auto reader = repo.createObjectReader();
    auto obj = reader.read(oid);
    return obj.data;
}

/// Write blob and return its OID
Git.OID writeBlob(const(ubyte)[] data)
{
    auto writer = repo.createObjectWriter("blob");
    return writer.write(cast(immutable(ubyte)[])data);
}

/// Update an index entry using git update-index (handles locking)
void updateIndexEntry(uint mode, Git.OID oid, string path)
{
    repo.run("update-index", "--add", "--cacheinfo",
        format!"%o,%s,%s"(mode, oid.toString(), path));
}

/// Remove an index entry using git update-index (handles locking)
void removeIndexEntry(string path)
{
    repo.run("update-index", "--force-remove", path);
}

/// Change executable mode of an index entry
void chmodIndexEntry(string path, bool executable)
{
    repo.run("update-index", executable ? "--chmod=+x" : "--chmod=-x", path);
}


//==============================================================================
// Tree traversal for read-only commit access
//==============================================================================

struct TreeNode
{
    enum Type { blob, tree, commit }
    Type type;
    Git.OID oid;
    uint mode;
    ulong size; // for blobs
}

/// Resolve a path within a commit to a tree node
Nullable!TreeNode resolveTreePath(string commitSpec, string path)
{
    Nullable!TreeNode result;

    try
    {
        auto reader = repo.createObjectReader();

        // Get the commit
        Git.Object commitObj;
        try
        {
            commitObj = reader.read(commitSpec);
        }
        catch (Exception)
        {
            return result; // not found
        }

        if (commitObj.type != "commit")
            return result;

        auto parsedCommit = commitObj.parseCommit();
        auto treeOid = parsedCommit.tree.oid;

        if (path.length == 0)
        {
            // Root of commit
            result = TreeNode(TreeNode.Type.tree, treeOid, octal!40000, 0);
            return result;
        }

        // Walk the tree
        auto parts = path.split("/").filter!(p => p.length > 0).array;
        Git.OID currentOid = treeOid;

        foreach (i, part; parts)
        {
            auto treeObj = reader.read(currentOid);
            if (treeObj.type != "tree")
                return result; // not a tree

            auto entries = treeObj.parseTree();
            bool found = false;
            foreach (ref entry; entries)
            {
                if (entry.name == part)
                {
                    if (i == parts.length - 1)
                    {
                        // Final component
                        TreeNode node;
                        if ((entry.mode & octal!170000) == octal!40000)
                            node.type = TreeNode.Type.tree;
                        else if ((entry.mode & octal!170000) == octal!160000)
                            node.type = TreeNode.Type.commit;
                        else
                            node.type = TreeNode.Type.blob;
                        node.oid = entry.hash;
                        node.mode = entry.mode;
                        if (node.type == TreeNode.Type.blob)
                        {
                            auto blobObj = reader.read(entry.hash);
                            node.size = blobObj.data.length;
                        }
                        result = node;
                        return result;
                    }
                    else
                    {
                        currentOid = entry.hash;
                        found = true;
                        break;
                    }
                }
            }
            if (!found)
                return result; // path component not found
        }
    }
    catch (Exception)
    {
        // Any error means not found
    }

    return result;
}

/// List entries in a tree
string[] listTreeEntries(string commitSpec, string path)
{
    string[] result;

    try
    {
        auto reader = repo.createObjectReader();

        // Get the commit
        auto commitObj = reader.read(commitSpec);
        if (commitObj.type != "commit")
            return result;

        auto parsedCommit = commitObj.parseCommit();
        auto treeOid = parsedCommit.tree.oid;

        // Navigate to the path
        if (path.length > 0)
        {
            auto resolved = resolveTreePath(commitSpec, path);
            if (resolved.isNull || resolved.get.type != TreeNode.Type.tree)
                return result;
            treeOid = resolved.get.oid;
        }

        auto treeObj = reader.read(treeOid);
        auto entries = treeObj.parseTree();

        foreach (ref entry; entries)
            result ~= entry.name;
    }
    catch (Exception)
    {
    }

    return result;
}


//==============================================================================
// FUSE callbacks
//==============================================================================

extern(C) nothrow
{
    int fs_getattr(const char* c_path, stat_t* s)
    {
        return fuseWrap({
            auto fusePath = FusePath.parse(c_path);
            *s = stat_t.init;
            s.st_uid = getuid();
            s.st_gid = getgid();

            final switch (fusePath.type)
            {
                case FusePath.Type.invalid:
                    throw new ErrnoException("", ENOENT);

                case FusePath.Type.root:
                case FusePath.Type.indexRoot:
                case FusePath.Type.indexDir:
                case FusePath.Type.commitsRoot:
                case FusePath.Type.refsRoot:
                    s.st_mode = S_IFDIR | octal!755;
                    s.st_nlink = 2;
                    return;

                case FusePath.Type.indexFile:
                    auto entryOpt = findIndexEntry(fusePath.indexPath);
                    if (entryOpt.isNull)
                        throw new ErrnoException("", ENOENT);
                    auto entry = entryOpt.get;

                    // Check mode for file type
                    if ((entry.mode & octal!170000) == octal!120000)
                        s.st_mode = S_IFLNK | octal!777;
                    else if ((entry.mode & octal!111) != 0)
                        s.st_mode = S_IFREG | octal!755;
                    else
                        s.st_mode = S_IFREG | octal!644;

                    s.st_nlink = 1;

                    // Get actual blob size
                    try
                    {
                        auto data = readBlob(entry.oid);
                        s.st_size = data.length;
                    }
                    catch (Exception)
                    {
                        s.st_size = 0;
                    }
                    return;

                case FusePath.Type.commitDir:
                case FusePath.Type.refDir:
                    auto resolved = resolveTreePath(fusePath.commitOrRef, fusePath.treePath);
                    if (resolved.isNull)
                        throw new ErrnoException("", ENOENT);

                    if (resolved.get.type == TreeNode.Type.tree)
                    {
                        s.st_mode = S_IFDIR | octal!555;
                        s.st_nlink = 2;
                    }
                    else
                    {
                        s.st_mode = S_IFREG | octal!444;
                        s.st_nlink = 1;
                        s.st_size = resolved.get.size;
                    }
                    return;

                case FusePath.Type.commitFile:
                case FusePath.Type.refFile:
                    auto resolved = resolveTreePath(fusePath.commitOrRef, fusePath.treePath);
                    if (resolved.isNull)
                        throw new ErrnoException("", ENOENT);

                    if (resolved.get.type == TreeNode.Type.blob)
                    {
                        s.st_mode = S_IFREG | octal!444;
                        s.st_nlink = 1;
                        s.st_size = resolved.get.size;
                    }
                    else
                    {
                        s.st_mode = S_IFDIR | octal!555;
                        s.st_nlink = 2;
                    }
                    return;
            }
        });
    }

    int fs_readdir(const char* c_path, void* buf, fuse_fill_dir_t filler, off_t offset, fuse_file_info* fi)
    {
        return fuseWrap({
            auto fusePath = FusePath.parse(c_path);

            filler(buf, cast(char*)".".toStringz, null, 0);
            filler(buf, cast(char*)"..".toStringz, null, 0);

            final switch (fusePath.type)
            {
                case FusePath.Type.invalid:
                    throw new ErrnoException("", ENOENT);

                case FusePath.Type.root:
                    filler(buf, cast(char*)"index".toStringz, null, 0);
                    filler(buf, cast(char*)"commits".toStringz, null, 0);
                    // refs omitted for simplicity
                    return;

                case FusePath.Type.indexRoot:
                case FusePath.Type.indexDir:
                    auto dirPath = fusePath.type == FusePath.Type.indexRoot ? "" : fusePath.indexPath;
                    foreach (name; getIndexDirEntries(dirPath))
                        filler(buf, cast(char*)name.toStringz, null, 0);
                    return;

                case FusePath.Type.indexFile:
                    throw new ErrnoException("", ENOTDIR);

                case FusePath.Type.commitsRoot:
                    // Don't list all commits, that would be huge
                    // User can access commits directly by hash
                    return;

                case FusePath.Type.refsRoot:
                    // Could list refs here
                    return;

                case FusePath.Type.commitDir:
                case FusePath.Type.refDir:
                    foreach (name; listTreeEntries(fusePath.commitOrRef, fusePath.treePath))
                        filler(buf, cast(char*)name.toStringz, null, 0);
                    return;

                case FusePath.Type.commitFile:
                case FusePath.Type.refFile:
                    throw new ErrnoException("", ENOTDIR);
            }
        });
    }

    int fs_read(const char* c_path, char* buf_ptr, size_t size, off_t offset, fuse_file_info* fi)
    {
        return fuseWrap({
            auto fusePath = FusePath.parse(c_path);

            immutable(ubyte)[] data;

            final switch (fusePath.type)
            {
                case FusePath.Type.invalid:
                case FusePath.Type.root:
                case FusePath.Type.indexRoot:
                case FusePath.Type.indexDir:
                case FusePath.Type.commitsRoot:
                case FusePath.Type.refsRoot:
                    throw new ErrnoException("", EISDIR);

                case FusePath.Type.indexFile:
                    auto entryOpt = findIndexEntry(fusePath.indexPath);
                    if (entryOpt.isNull)
                        throw new ErrnoException("", ENOENT);
                    data = readBlob(entryOpt.get.oid);
                    break;

                case FusePath.Type.commitDir:
                case FusePath.Type.refDir:
                case FusePath.Type.commitFile:
                case FusePath.Type.refFile:
                    auto resolved = resolveTreePath(fusePath.commitOrRef, fusePath.treePath);
                    if (resolved.isNull)
                        throw new ErrnoException("", ENOENT);
                    if (resolved.get.type != TreeNode.Type.blob)
                        throw new ErrnoException("", EISDIR);

                    auto reader = repo.createObjectReader();
                    auto obj = reader.read(resolved.get.oid);
                    data = obj.data;
                    break;
            }

            if (offset >= data.length)
                return 0;

            auto bytesToRead = min(size, data.length - offset);
            buf_ptr[0 .. bytesToRead] = cast(char[])data[offset .. offset + bytesToRead];
            return cast(int)bytesToRead;
        });
    }

    int fs_write(const char* c_path, const char* data_ptr, size_t size, off_t offset, fuse_file_info* fi)
    {
        return fuseWrap({
            auto fusePath = FusePath.parse(c_path);

            if (fusePath.type != FusePath.Type.indexFile)
                throw new ErrnoException("", EROFS);

            auto entryOpt = findIndexEntry(fusePath.indexPath);
            if (entryOpt.isNull)
                throw new ErrnoException("", ENOENT);
            auto entry = entryOpt.get;

            // Read existing content
            ubyte[] content;
            try
            {
                content = readBlob(entry.oid).dup;
            }
            catch (Exception)
            {
                content = [];
            }

            // Expand if necessary
            auto endOffset = offset + size;
            if (endOffset > content.length)
                content.length = endOffset;

            // Write new data
            content[offset .. offset + size] = cast(ubyte[])data_ptr[0 .. size];

            // Write blob and update index (git update-index handles locking)
            auto newOid = writeBlob(content);
            updateIndexEntry(entry.mode, newOid, fusePath.indexPath);

            return cast(int)size;
        });
    }

    int fs_truncate(const char* c_path, off_t length)
    {
        return fuseWrap({
            auto fusePath = FusePath.parse(c_path);

            if (fusePath.type != FusePath.Type.indexFile)
                throw new ErrnoException("", EROFS);

            enforce(length >= 0, new ErrnoException("", EINVAL));

            auto entryOpt = findIndexEntry(fusePath.indexPath);
            if (entryOpt.isNull)
                throw new ErrnoException("", ENOENT);
            auto entry = entryOpt.get;

            // Read existing content
            ubyte[] content;
            try
            {
                content = readBlob(entry.oid).dup;
            }
            catch (Exception)
            {
                content = [];
            }

            // Truncate or extend
            content.length = length;

            // Write blob and update index (git update-index handles locking)
            auto newOid = writeBlob(content);
            updateIndexEntry(entry.mode, newOid, fusePath.indexPath);
        });
    }

    int fs_mknod(const char* c_path, uint mode, ulong dev)
    {
        return fuseWrap({
            auto fusePath = FusePath.parse(c_path);

            // Can only create in index
            if (fusePath.type != FusePath.Type.invalid)
            {
                // Path already exists or is a special path
                if (fusePath.type == FusePath.Type.indexFile)
                    throw new ErrnoException("", EEXIST);
                throw new ErrnoException("", EROFS);
            }

            // Check if this should be an index file
            auto path = c_path.fromStringz.idup;
            if (!path.startsWith("/index/"))
                throw new ErrnoException("", EROFS);

            auto indexPath = path[7 .. $]; // strip "/index/"
            if (indexPath.length == 0)
                throw new ErrnoException("", EINVAL);

            enforce(S_ISREG(mode), new ErrnoException("", EOPNOTSUPP));

            // Create empty blob and add to index (git update-index handles locking)
            auto emptyOid = writeBlob([]);
            auto gitMode = (mode & octal!111) ? octal!100755 : octal!100644;
            updateIndexEntry(gitMode, emptyOid, indexPath);
        });
    }

    int fs_unlink(const char* c_path)
    {
        return fuseWrap({
            auto fusePath = FusePath.parse(c_path);

            if (fusePath.type != FusePath.Type.indexFile)
                throw new ErrnoException("", EROFS);

            // git update-index --force-remove handles locking
            removeIndexEntry(fusePath.indexPath);
        });
    }

    int fs_mkdir(const char* c_path, uint mode)
    {
        return fuseWrap({
            // Git index doesn't track directories, only files
            // We silently succeed for index directories
            auto path = c_path.fromStringz.idup;
            if (!path.startsWith("/index/"))
                throw new ErrnoException("", EROFS);
            // Just succeed - directories are implicit in git
        });
    }

    int fs_rmdir(const char* c_path)
    {
        return fuseWrap({
            auto fusePath = FusePath.parse(c_path);

            if (fusePath.type != FusePath.Type.indexDir)
                throw new ErrnoException("", EROFS);

            // Check if directory is empty
            auto entries = getIndexDirEntries(fusePath.indexPath);
            if (entries.length > 0)
                throw new ErrnoException("", ENOTEMPTY);

            // Empty directories don't exist in git, so just succeed
        });
    }

    int fs_rename(const char* c_from, const char* c_to)
    {
        return fuseWrap({
            auto fromPath = FusePath.parse(c_from);

            // Only index files can be renamed
            if (fromPath.type != FusePath.Type.indexFile)
                throw new ErrnoException("", EROFS);

            auto toPathStr = c_to.fromStringz.idup;
            if (!toPathStr.startsWith("/index/"))
                throw new ErrnoException("", EROFS);

            auto newIndexPath = toPathStr[7 .. $];

            // Find source entry
            auto entryOpt = findIndexEntry(fromPath.indexPath);
            if (entryOpt.isNull)
                throw new ErrnoException("", ENOENT);
            auto entry = entryOpt.get;

            // Remove target if exists, add new entry, remove old entry
            // git update-index handles locking for each operation
            if (!findIndexEntry(newIndexPath).isNull)
                removeIndexEntry(newIndexPath);

            updateIndexEntry(entry.mode, entry.oid, newIndexPath);
            removeIndexEntry(fromPath.indexPath);
        });
    }

    int fs_chmod(const char* c_path, uint mode)
    {
        return fuseWrap({
            auto fusePath = FusePath.parse(c_path);

            if (fusePath.type != FusePath.Type.indexFile)
                throw new ErrnoException("", EROFS);

            auto entryOpt = findIndexEntry(fusePath.indexPath);
            if (entryOpt.isNull)
                throw new ErrnoException("", ENOENT);
            auto entry = entryOpt.get;

            // Git only tracks executable bit for regular files
            if ((entry.mode & octal!170000) != octal!120000) // not symlink
            {
                // Use git update-index --chmod (handles locking)
                chmodIndexEntry(fusePath.indexPath, (mode & octal!111) != 0);
            }
        });
    }

    int fs_access(const char* c_path, int mode)
    {
        return fuseWrap({
            auto fusePath = FusePath.parse(c_path);

            if (fusePath.type == FusePath.Type.invalid)
                throw new ErrnoException("", ENOENT);

            // Check write access
            if ((mode & W_OK) != 0)
            {
                // Only index files are writable
                if (fusePath.type != FusePath.Type.indexFile &&
                    fusePath.type != FusePath.Type.indexDir &&
                    fusePath.type != FusePath.Type.indexRoot)
                    throw new ErrnoException("", EROFS);
            }
        });
    }

    int fs_open(const char* c_path, fuse_file_info* fi)
    {
        return fuseWrap({
            auto fusePath = FusePath.parse(c_path);

            // Handle O_TRUNC flag - truncate file on open
            if ((fi.flags & O_TRUNC) != 0)
            {
                if (fusePath.type == FusePath.Type.indexFile)
                {
                    auto entryOpt = findIndexEntry(fusePath.indexPath);
                    if (!entryOpt.isNull)
                    {
                        // Truncate to empty (git update-index handles locking)
                        auto emptyOid = writeBlob([]);
                        updateIndexEntry(entryOpt.get.mode, emptyOid, fusePath.indexPath);
                    }
                }
            }
        });
    }

    // No flush/fsync/release/destroy needed - each git update-index is atomic
}


//==============================================================================
// Main
//==============================================================================

int gitFuse(
    Parameter!(string, "Path to the Git repository to mount.") repoPath,
    Parameter!(string, "Directory path where the filesystem should be mounted.") mountPath,
    Switch!("Run in foreground.", 'f') foreground = false,
    Option!(string[], "Additional FUSE options (e.g. debug).", "STR", 'o') options = null,
)
{
    // Initialize repository
    repo = Git(repoPath.absolutePath);

    // Setup FUSE operations
    fuse_operations fsops;
    fsops.getattr = &fs_getattr;
    fsops.readdir = &fs_readdir;
    fsops.read = &fs_read;
    fsops.write = &fs_write;
    fsops.truncate = &fs_truncate;
    fsops.mknod = &fs_mknod;
    fsops.unlink = &fs_unlink;
    fsops.mkdir = &fs_mkdir;
    fsops.rmdir = &fs_rmdir;
    fsops.rename = &fs_rename;
    fsops.chmod = &fs_chmod;
    fsops.access = &fs_access;
    fsops.open = &fs_open;

    // Build FUSE arguments
    string[] args = ["git-fuse", mountPath];

    if (options.length > 0)
        args ~= "-o%-(%s,%)".format(options);

    args ~= "-s"; // single-threaded for simplicity

    if (foreground)
        args ~= "-f";

    auto c_args = new char*[args.length];
    foreach (i, arg; args)
        c_args[i] = cast(char*)arg.toStringz;
    auto f_args = FUSE_ARGS_INIT(cast(int)c_args.length, c_args.ptr);

    stderr.writeln("Mounting Git repository: ", repoPath);
    stderr.writeln("Mount point: ", mountPath);
    scope(success) stderr.writeln("git-fuse exiting.");

    return fuse_main(f_args.argc, f_args.argv, &fsops, null);
}

mixin main!(funopt!gitFuse);
