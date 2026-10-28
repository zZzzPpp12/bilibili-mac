import AppKit
import ImageIO
import UniformTypeIdentifiers

// Original code-drawn icon. No remote images or third-party brand artwork.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let context = CGContext(data:nil,width:pixels,height:pixels,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
    let bounds = CGRect(x:70,y:70,width:884,height:884)
    let background = CGPath(roundedRect:bounds,cornerWidth:200,cornerHeight:200,transform:nil)
    context.addPath(background); context.clip()
    let gradient = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[NSColor(red:1,green:0.44,blue:0.58,alpha:1).cgColor,NSColor(red:0.84,green:0.19,blue:0.43,alpha:1).cgColor] as CFArray,locations:[0,1])!
    context.drawLinearGradient(gradient,start:CGPoint(x:180,y:900),end:CGPoint(x:900,y:80),options:[])
    context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(45)
    context.addPath(CGPath(roundedRect:CGRect(x:228,y:308,width:568,height:412),cornerWidth:90,cornerHeight:90,transform:nil)); context.strokePath()
    context.move(to:CGPoint(x:380,y:720)); context.addLine(to:CGPoint(x:320,y:810))
    context.move(to:CGPoint(x:644,y:720)); context.addLine(to:CGPoint(x:704,y:810)); context.strokePath()
    context.setFillColor(NSColor.white.cgColor)
    context.move(to:CGPoint(x:463,y:415)); context.addLine(to:CGPoint(x:463,y:612)); context.addLine(to:CGPoint(x:626,y:514)); context.closePath(); context.fillPath()
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name+".png") as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,image,nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Icon encoding failed") }
}
