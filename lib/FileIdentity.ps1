# Metadata-only NTFS identity. Zero desired access and OPEN_REPARSE_POINT avoid
# opening placeholder content. Unsupported providers/filesystems return no ID;
# they continue through the ordinary copy/delete classification.
if (-not ('DriveRelay.FileIdentity' -as [type])) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace DriveRelay {
    public static class FileIdentity {
        [StructLayout(LayoutKind.Sequential)]
        private struct Info {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle file, out Info info);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool GetVolumeInformationByHandleW(SafeFileHandle file,
            StringBuilder name, uint nameSize, out uint serial, out uint maxComponent,
            out uint flags, StringBuilder filesystem, uint filesystemSize);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool MoveFileExW(string source, string destination, uint flags);

        public static string Get(string path) {
            using (SafeFileHandle file = CreateFileW(path, 0, 7, IntPtr.Zero, 3,
                                                    0x02200000, IntPtr.Zero)) {
                if (file.IsInvalid) return null;
                Info info;
                if (!GetFileInformationByHandle(file, out info) || info.Links != 1 ||
                    (info.IndexHigh == 0 && info.IndexLow == 0)) return null;
                uint serial, maxComponent, flags;
                var filesystem = new StringBuilder(32);
                if (!GetVolumeInformationByHandleW(file, null, 0, out serial,
                    out maxComponent, out flags, filesystem, 32) ||
                    filesystem.ToString() != "NTFS") return null;
                // Creation time also guards against a deleted file's ID being reused.
                return String.Format("{0:X8}:{1:X8}{2:X8}:{3:X8}{4:X8}", info.Volume,
                    info.IndexHigh, info.IndexLow, info.Creation.dwHighDateTime,
                    info.Creation.dwLowDateTime);
            }
        }
        public static void Move(string source, string destination) {
            // No REPLACE_EXISTING and no COPY_ALLOWED: never overwrite or fall
            // back to copying across volumes (including mounted subvolumes).
            if (!MoveFileExW(source, destination, 0))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@ -ErrorAction Stop
    }
    catch { if (-not ('DriveRelay.FileIdentity' -as [type])) { throw } }
}

function Get-FileIdentity {
    param([Parameter(Mandatory)][string] $Path)
    try { return [DriveRelay.FileIdentity]::Get($Path) }
    catch { return $null }
}
