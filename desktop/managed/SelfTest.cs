using System.Reflection;
using System.Security.Cryptography;

namespace UnlockPortable.Desktop;

internal static class SelfTest
{
    public static int Run(string[] args)
    {
        if (args.Length != 4) return 2;
        string encrypted = Path.GetFullPath(args[2]);
        byte[] expected = File.ReadAllBytes(args[3]);
        string root = Path.Combine(Path.GetTempPath(), "unlock-desktop-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            foreach (string extension in new[] { ".dll", ".ps1" })
            {
                string source = Path.Combine(root, "sample" + extension);
                File.Copy(encrypted, source);
                if (extension == ".dll") File.SetAttributes(source, FileAttributes.ReadOnly);
                var result = typeof(CryptoEngine).GetMethod("Inspect", BindingFlags.Public | BindingFlags.Static)!.Invoke(null, [source]);
                string kind = (string)result!.GetType().GetProperty("Kind")!.GetValue(result)!;
                if (kind != "Supported") throw new InvalidOperationException("fixture was not detected");
                typeof(CryptoEngine).GetMethod("DecryptInPlace", BindingFlags.Public | BindingFlags.Static)!.Invoke(null, [source, null]);
                if (!File.ReadAllBytes(source).SequenceEqual(expected)) throw new InvalidOperationException(extension + " plaintext mismatch");
                if (Directory.GetFiles(root, "*.tmp").Length != 0) throw new InvalidOperationException("temporary output was left behind");
            }
            Console.WriteLine("PASS: encrypted detection, byte-exact in-place replacement, read-only handling, .ps1 restoration, no temp leftovers.");
            return 0;
        }
        finally
        {
            foreach (string file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
                File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(root, true);
        }
    }
}
