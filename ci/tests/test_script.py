# git-fuse integration test script

import time


def setup_git_repo():
    """Create a test git repository with some staged files."""
    machine.succeed("mkdir -p /tmp/test-repo")
    machine.succeed("cd /tmp/test-repo && git init")
    machine.succeed("cd /tmp/test-repo && git config user.email 'test@test.com'")
    machine.succeed("cd /tmp/test-repo && git config user.name 'Test User'")

    # Create and stage some files
    machine.succeed("echo 'hello world' > /tmp/test-repo/file1.txt")
    machine.succeed("echo 'second file' > /tmp/test-repo/file2.txt")
    machine.succeed("mkdir -p /tmp/test-repo/subdir")
    machine.succeed("echo 'nested file' > /tmp/test-repo/subdir/nested.txt")
    machine.succeed("cd /tmp/test-repo && git add .")


def mount_git_fuse():
    """Mount the git repository using git-fuse."""
    machine.succeed("mkdir -p /mnt/git")
    # Run git-fuse in foreground mode, backgrounded
    machine.succeed("cd /tmp/test-repo && git-fuse . /mnt/git &")
    # Wait for mount to be ready
    time.sleep(1)
    machine.succeed("mountpoint /mnt/git")


def unmount_git_fuse():
    """Unmount the git-fuse filesystem."""
    machine.succeed("fusermount -u /mnt/git || umount /mnt/git")


def test_read_index():
    """Test reading files from the index."""
    # Check that index directory exists
    machine.succeed("test -d /mnt/git/index")

    # Read staged files
    output = machine.succeed("cat /mnt/git/index/file1.txt")
    assert output.strip() == "hello world", f"Expected 'hello world', got '{output.strip()}'"

    output = machine.succeed("cat /mnt/git/index/file2.txt")
    assert output.strip() == "second file", f"Expected 'second file', got '{output.strip()}'"

    output = machine.succeed("cat /mnt/git/index/subdir/nested.txt")
    assert output.strip() == "nested file", f"Expected 'nested file', got '{output.strip()}'"

    # List files
    output = machine.succeed("ls /mnt/git/index/")
    assert "file1.txt" in output
    assert "file2.txt" in output
    assert "subdir" in output


def test_write_index():
    """Test writing/modifying files in the index."""
    # Modify an existing file
    machine.succeed("echo 'modified content' > /mnt/git/index/file1.txt")

    # Verify the change via git
    output = machine.succeed("cd /tmp/test-repo && git diff --cached --name-only")
    # file1.txt should show as modified (or in the index)

    # Read back through FUSE to verify
    output = machine.succeed("cat /mnt/git/index/file1.txt")
    assert output.strip() == "modified content", f"Expected 'modified content', got '{output.strip()}'"


def test_create_file():
    """Test creating a new file in the index."""
    machine.succeed("echo 'new file content' > /mnt/git/index/newfile.txt")

    # Verify the file is staged
    output = machine.succeed("cd /tmp/test-repo && git ls-files")
    assert "newfile.txt" in output, f"Expected newfile.txt in staged files, got: {output}"

    # Read back
    output = machine.succeed("cat /mnt/git/index/newfile.txt")
    assert output.strip() == "new file content"


def test_delete_file():
    """Test removing a file from the index."""
    machine.succeed("rm /mnt/git/index/file2.txt")

    # Verify the file is no longer staged
    output = machine.succeed("cd /tmp/test-repo && git ls-files")
    assert "file2.txt" not in output, f"file2.txt should be removed from index, got: {output}"


def test_read_commits():
    """Test reading from commits (read-only)."""
    # First create a commit
    machine.succeed("cd /tmp/test-repo && git commit -m 'Initial commit'")

    # Get the commit hash
    commit_hash = machine.succeed("cd /tmp/test-repo && git rev-parse HEAD").strip()

    # Read from the commit
    output = machine.succeed(f"ls /mnt/git/commits/{commit_hash}/")
    assert "file1.txt" in output or "subdir" in output


def test_mkdir():
    """Test creating a single ephemeral directory."""
    # Create a directory
    machine.succeed("mkdir /mnt/git/index/newdir")

    # Verify it exists
    machine.succeed("test -d /mnt/git/index/newdir")

    # Verify it shows up in listing
    output = machine.succeed("ls /mnt/git/index/")
    assert "newdir" in output, f"Expected newdir in listing, got: {output}"

    # Verify rmdir works
    machine.succeed("rmdir /mnt/git/index/newdir")

    # Verify it's gone
    machine.fail("test -d /mnt/git/index/newdir")


def test_mkdir_p():
    """Test creating nested directories with mkdir -p."""
    # Create nested directories
    machine.succeed("mkdir -p /mnt/git/index/a/b/c")

    # Verify all levels exist
    machine.succeed("test -d /mnt/git/index/a")
    machine.succeed("test -d /mnt/git/index/a/b")
    machine.succeed("test -d /mnt/git/index/a/b/c")

    # Verify listing at each level
    output = machine.succeed("ls /mnt/git/index/")
    assert "a" in output

    output = machine.succeed("ls /mnt/git/index/a/")
    assert "b" in output

    output = machine.succeed("ls /mnt/git/index/a/b/")
    assert "c" in output

    # Create a file in the deepest directory
    machine.succeed("echo 'deep file' > /mnt/git/index/a/b/c/deep.txt")

    # Verify file exists and is in git index
    output = machine.succeed("cd /tmp/test-repo && git ls-files")
    assert "a/b/c/deep.txt" in output, f"Expected a/b/c/deep.txt in git index, got: {output}"

    # Read back the file
    output = machine.succeed("cat /mnt/git/index/a/b/c/deep.txt")
    assert output.strip() == "deep file"


def test_rm_r():
    """Test recursive deletion with rm -r."""
    # First verify our directory tree from previous test exists
    machine.succeed("test -d /mnt/git/index/a/b/c")
    machine.succeed("test -f /mnt/git/index/a/b/c/deep.txt")

    # Add more files at different levels
    machine.succeed("echo 'file at a' > /mnt/git/index/a/file_a.txt")
    machine.succeed("echo 'file at b' > /mnt/git/index/a/b/file_b.txt")

    # Verify files are in git index
    output = machine.succeed("cd /tmp/test-repo && git ls-files")
    assert "a/file_a.txt" in output
    assert "a/b/file_b.txt" in output

    # Delete entire tree with rm -r
    machine.succeed("rm -r /mnt/git/index/a")

    # Verify directory is gone
    machine.fail("test -d /mnt/git/index/a")

    # Verify files are removed from git index
    output = machine.succeed("cd /tmp/test-repo && git ls-files")
    assert "a/file_a.txt" not in output, f"a/file_a.txt should be removed, got: {output}"
    assert "a/b/file_b.txt" not in output, f"a/b/file_b.txt should be removed, got: {output}"
    assert "a/b/c/deep.txt" not in output, f"a/b/c/deep.txt should be removed, got: {output}"


def test_ephemeral_after_delete():
    """Test that directories become ephemeral after deleting all files."""
    # Create a directory with a file
    machine.succeed("mkdir -p /mnt/git/index/ephtest")
    machine.succeed("echo 'temp' > /mnt/git/index/ephtest/temp.txt")

    # Verify file is in git index
    output = machine.succeed("cd /tmp/test-repo && git ls-files")
    assert "ephtest/temp.txt" in output

    # Delete the file (not the directory)
    machine.succeed("rm /mnt/git/index/ephtest/temp.txt")

    # Directory should still exist (as ephemeral)
    machine.succeed("test -d /mnt/git/index/ephtest")

    # Directory should be empty
    output = machine.succeed("ls /mnt/git/index/ephtest/")
    assert output.strip() == "", f"Expected empty directory, got: {output}"

    # Should be able to rmdir it now
    machine.succeed("rmdir /mnt/git/index/ephtest")

    # Verify it's gone
    machine.fail("test -d /mnt/git/index/ephtest")


def test_mkdir_errors():
    """Test mkdir error cases."""
    # mkdir on existing file should fail
    machine.fail("mkdir /mnt/git/index/file1.txt")

    # mkdir on existing directory should fail
    machine.succeed("mkdir /mnt/git/index/testdir")
    machine.fail("mkdir /mnt/git/index/testdir")
    machine.succeed("rmdir /mnt/git/index/testdir")

    # mkdir with non-existent parent should fail
    machine.fail("mkdir /mnt/git/index/nonexistent/child")


def test_rmdir_errors():
    """Test rmdir error cases."""
    # rmdir on non-empty directory should fail
    machine.succeed("mkdir -p /mnt/git/index/nonempty")
    machine.succeed("echo 'x' > /mnt/git/index/nonempty/file.txt")
    machine.fail("rmdir /mnt/git/index/nonempty")

    # Clean up
    machine.succeed("rm -r /mnt/git/index/nonempty")


# =============================================================================
# Main Test Execution
# =============================================================================

with subtest("Setup git repository"):
    setup_git_repo()

with subtest("Mount git-fuse"):
    mount_git_fuse()

with subtest("Read from index"):
    test_read_index()

with subtest("Write to index"):
    test_write_index()

with subtest("Create new file in index"):
    test_create_file()

with subtest("Delete file from index"):
    test_delete_file()

with subtest("Read from commits"):
    test_read_commits()

with subtest("mkdir single directory"):
    test_mkdir()

with subtest("mkdir -p nested directories"):
    test_mkdir_p()

with subtest("rm -r recursive deletion"):
    test_rm_r()

with subtest("Ephemeral directories after file deletion"):
    test_ephemeral_after_delete()

with subtest("mkdir error cases"):
    test_mkdir_errors()

with subtest("rmdir error cases"):
    test_rmdir_errors()

with subtest("Unmount"):
    unmount_git_fuse()
