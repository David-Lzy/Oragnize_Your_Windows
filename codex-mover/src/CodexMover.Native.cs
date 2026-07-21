using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

public static class CodexMoverNative
{
    private const int ErrorFileNotFound = 2;
    private const int ErrorPathNotFound = 3;
    private const int ErrorNoMoreFiles = 18;
    private const uint InvalidFileAttributes = 0xFFFFFFFF;
    private static readonly IntPtr InvalidHandleValue = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Win32FindData
    {
        public FileAttributes FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint Reserved0;
        public uint Reserved1;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string FileName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
        public string AlternateFileName;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool MoveFileExW(string existingPath, string newPath, int flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindFirstFileW(string fileName, out Win32FindData findData);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FindNextFileW(IntPtr findHandle, out Win32FindData findData);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FindClose(IntPtr findHandle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteFileW(string fileName);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveDirectoryW(string pathName);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileAttributesW(string fileName, FileAttributes fileAttributes);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFileAttributesW(string fileName);

    public static void MoveDirectory(string source, string destination)
    {
        if (String.IsNullOrWhiteSpace(source) || String.IsNullOrWhiteSpace(destination))
        {
            throw new ArgumentException("Source and destination are required.");
        }

        if (!MoveFileExW(source, destination, 8))
        {
            int error = Marshal.GetLastWin32Error();
            string systemMessage = new Win32Exception(error).Message;
            throw new Win32Exception(
                error,
                "Atomic directory rename failed: " + source + " -> " + destination +
                " (Win32 error " + error + ": " + systemMessage + ")");
        }
    }

    public static void DeleteTreeNoFollow(string path)
    {
        if (String.IsNullOrWhiteSpace(path))
        {
            throw new ArgumentException("Deletion path is empty.", "path");
        }

        string fullPath = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
        string rootPath = Path.GetPathRoot(fullPath).TrimEnd(Path.DirectorySeparatorChar);
        if (String.Equals(fullPath, rootPath, StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("Refusing to delete a filesystem root.", "path");
        }
        string extendedPath = ToExtendedPath(fullPath);
        uint rawAttributes = GetFileAttributesW(extendedPath);
        if (rawAttributes == InvalidFileAttributes)
        {
            ThrowWin32("read deletion-root attributes", extendedPath, Marshal.GetLastWin32Error());
        }
        FileAttributes attributes = (FileAttributes)rawAttributes;
        if ((attributes & FileAttributes.ReparsePoint) != 0)
        {
            if ((attributes & FileAttributes.Directory) != 0)
            {
                if (!RemoveDirectoryW(extendedPath))
                {
                    ThrowWin32("remove deletion-root link", extendedPath, Marshal.GetLastWin32Error());
                }
            }
            else if (!DeleteFileW(extendedPath))
            {
                ThrowWin32("remove deletion-root file link", extendedPath, Marshal.GetLastWin32Error());
            }
            return;
        }
        DeleteDirectoryContentsAndSelf(extendedPath);
    }

    public static void RemoveDirectoryLink(string path)
    {
        if (String.IsNullOrWhiteSpace(path))
        {
            throw new ArgumentException("Link path is empty.", "path");
        }

        string extendedPath = ToExtendedPath(Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar));
        uint rawAttributes = GetFileAttributesW(extendedPath);
        if (rawAttributes == InvalidFileAttributes)
        {
            ThrowWin32("read link attributes", extendedPath, Marshal.GetLastWin32Error());
        }

        FileAttributes attributes = (FileAttributes)rawAttributes;
        if ((attributes & FileAttributes.Directory) == 0 || (attributes & FileAttributes.ReparsePoint) == 0)
        {
            throw new ArgumentException("Path is not a directory reparse point: " + path, "path");
        }
        if (!RemoveDirectoryW(extendedPath))
        {
            ThrowWin32("remove directory link", extendedPath, Marshal.GetLastWin32Error());
        }
    }

    private static string ToExtendedPath(string path)
    {
        if (path.StartsWith(@"\\?\", StringComparison.Ordinal))
        {
            return path;
        }

        if (path.StartsWith(@"\\", StringComparison.Ordinal))
        {
            return @"\\?\UNC\" + path.Substring(2);
        }

        return @"\\?\" + path;
    }

    private static void DeleteDirectoryContentsAndSelf(string directoryPath)
    {
        Win32FindData findData;
        IntPtr findHandle = FindFirstFileW(directoryPath + @"\*", out findData);
        if (findHandle == InvalidHandleValue)
        {
            int initialError = Marshal.GetLastWin32Error();
            if (initialError != ErrorFileNotFound && initialError != ErrorPathNotFound)
            {
                ThrowWin32("enumerate", directoryPath, initialError);
            }
        }
        else
        {
            try
            {
                while (true)
                {
                    string name = findData.FileName;
                    if (name != "." && name != "..")
                    {
                        string childPath = directoryPath + @"\" + name;
                        bool isDirectory = (findData.FileAttributes & FileAttributes.Directory) != 0;
                        bool isReparsePoint = (findData.FileAttributes & FileAttributes.ReparsePoint) != 0;

                        if (isReparsePoint)
                        {
                            if (isDirectory)
                            {
                                RemoveDirectoryOnly(childPath);
                            }
                            else
                            {
                                DeleteFileOnly(childPath);
                            }
                        }
                        else if (isDirectory)
                        {
                            DeleteDirectoryContentsAndSelf(childPath);
                        }
                        else
                        {
                            DeleteFileOnly(childPath);
                        }
                    }

                    if (!FindNextFileW(findHandle, out findData))
                    {
                        int nextError = Marshal.GetLastWin32Error();
                        if (nextError != ErrorNoMoreFiles)
                        {
                            ThrowWin32("continue enumeration", directoryPath, nextError);
                        }
                        break;
                    }
                }
            }
            finally
            {
                FindClose(findHandle);
            }
        }

        RemoveDirectoryOnly(directoryPath);
    }

    private static void DeleteFileOnly(string filePath)
    {
        if (DeleteFileW(filePath))
        {
            return;
        }

        int firstError = Marshal.GetLastWin32Error();
        SetFileAttributesW(filePath, FileAttributes.Normal);
        if (!DeleteFileW(filePath))
        {
            int retryError = Marshal.GetLastWin32Error();
            ThrowWin32("delete file", filePath, retryError != 0 ? retryError : firstError);
        }
    }

    private static void RemoveDirectoryOnly(string directoryPath)
    {
        if (RemoveDirectoryW(directoryPath))
        {
            return;
        }

        int firstError = Marshal.GetLastWin32Error();
        SetFileAttributesW(directoryPath, FileAttributes.Normal);
        if (!RemoveDirectoryW(directoryPath))
        {
            int retryError = Marshal.GetLastWin32Error();
            ThrowWin32("remove directory", directoryPath, retryError != 0 ? retryError : firstError);
        }
    }

    private static void ThrowWin32(string action, string path, int errorCode)
    {
        throw new Win32Exception(errorCode, action + " failed for " + path);
    }
}
