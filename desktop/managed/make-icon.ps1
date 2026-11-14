$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Collections.Generic;
public static class IconMaker {
    static byte[] Make(int size) {
        using (var b = new Bitmap(size,size,PixelFormat.Format32bppArgb))
        using (var g = Graphics.FromImage(b)) {
            g.SmoothingMode=SmoothingMode.AntiAlias; g.Clear(Color.Transparent);
            float u=size/64f;
            using (var p=new GraphicsPath()) {
                float r=12*u;
                p.AddArc(4*u,4*u,r,r,180,90); p.AddArc(60*u-r,4*u,r,r,270,90);
                p.AddArc(60*u-r,60*u-r,r,r,0,90); p.AddArc(4*u,60*u-r,r,r,90,90); p.CloseFigure();
                using(var brush=new SolidBrush(Color.FromArgb(8,127,120))) g.FillPath(brush,p);
            }
            using(var pen=new Pen(Color.White,4*u)) {
                pen.StartCap=LineCap.Round; pen.EndCap=LineCap.Round;
                g.DrawLines(pen,new PointF[]{new PointF(19*u,22*u),new PointF(19*u,14*u),new PointF(24*u,8*u),new PointF(40*u,8*u),new PointF(45*u,14*u),new PointF(45*u,22*u)});
                g.DrawArc(pen,17*u,18*u,30*u,37*u,180,180);
            }
            using(var pen=new Pen(Color.White,3*u)) { pen.StartCap=LineCap.Round; pen.EndCap=LineCap.Round; g.DrawLine(pen,25*u,34*u,39*u,34*u); g.DrawLine(pen,25*u,41*u,36*u,41*u); }
            using(var brush=new SolidBrush(Color.White)) g.FillEllipse(brush,29*u,27*u,6*u,6*u);
            using(var ms=new MemoryStream()) { b.Save(ms,ImageFormat.Png); return ms.ToArray(); }
        }
    }
    public static void Write(string path) {
        int[] sizes={16,24,32,48,64,128,256}; var images=new List<byte[]>(); foreach(int size in sizes) images.Add(Make(size));
        using(var fs=new FileStream(path,FileMode.Create,FileAccess.Write)) using(var w=new BinaryWriter(fs)) {
            w.Write((short)0); w.Write((short)1); w.Write((short)sizes.Length); int offset=6+16*sizes.Length;
            for(int i=0;i<sizes.Length;i++){int n=sizes[i];w.Write((byte)(n==256?0:n));w.Write((byte)(n==256?0:n));w.Write((byte)0);w.Write((byte)0);w.Write((short)1);w.Write((short)32);w.Write(images[i].Length);w.Write(offset);offset+=images[i].Length;}
            foreach(byte[] image in images) w.Write(image);
        }
    }
}
'@
[IconMaker]::Write((Join-Path $PSScriptRoot 'unlock-icon.ico'))
