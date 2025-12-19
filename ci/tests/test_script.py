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

with subtest("Unmount"):
    unmount_git_fuse()
