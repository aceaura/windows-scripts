//go:build ignore

package main

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/png"
	"os"
)

func main() {
	// Read PNG
	f, _ := os.Open("icon.png")
	defer f.Close()
	img, _ := png.Decode(f)

	// Convert to 256x256 32-bit BGRA bitmap for ICO
	bounds := img.Bounds()
	w, h := bounds.Dx(), bounds.Dy()
	bmpData := make([]byte, w*h*4)
	// ICO bitmaps are bottom-up
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			r, g, b, a := img.At(x, y).RGBA()
			offset := ((h-1-y)*w + x) * 4
			bmpData[offset+0] = byte(b >> 8) // B
			bmpData[offset+1] = byte(g >> 8) // G
			bmpData[offset+2] = byte(r >> 8) // R
			bmpData[offset+3] = byte(a >> 8) // A
		}
	}

	// Build ICO file in memory
	var ico bytes.Buffer
	// ICONDIR header
	binary.Write(&ico, binary.LittleEndian, uint16(0)) // reserved
	binary.Write(&ico, binary.LittleEndian, uint16(1)) // type: icon
	binary.Write(&ico, binary.LittleEndian, uint16(1)) // count

	// BMP info header size
	bmpHeaderSize := 40
	imageSize := len(bmpData)
	dataSize := bmpHeaderSize + imageSize

	// ICONDIRENTRY
	ico.WriteByte(0)                                          // width (0 = 256)
	ico.WriteByte(0)                                          // height (0 = 256)
	ico.WriteByte(0)                                          // color count
	ico.WriteByte(0)                                          // reserved
	binary.Write(&ico, binary.LittleEndian, uint16(1))        // planes
	binary.Write(&ico, binary.LittleEndian, uint16(32))       // bits per pixel
	binary.Write(&ico, binary.LittleEndian, uint32(dataSize)) // data size
	binary.Write(&ico, binary.LittleEndian, uint32(6+16))     // data offset (header + 1 entry)

	// BITMAPINFOHEADER
	binary.Write(&ico, binary.LittleEndian, uint32(bmpHeaderSize))
	binary.Write(&ico, binary.LittleEndian, int32(w))
	binary.Write(&ico, binary.LittleEndian, int32(h*2)) // height * 2 for ICO
	binary.Write(&ico, binary.LittleEndian, uint16(1))  // planes
	binary.Write(&ico, binary.LittleEndian, uint16(32)) // bpp
	binary.Write(&ico, binary.LittleEndian, uint32(0))  // compression
	binary.Write(&ico, binary.LittleEndian, uint32(imageSize))
	binary.Write(&ico, binary.LittleEndian, int32(0))  // x ppm
	binary.Write(&ico, binary.LittleEndian, int32(0))  // y ppm
	binary.Write(&ico, binary.LittleEndian, uint32(0)) // colors used
	binary.Write(&ico, binary.LittleEndian, uint32(0)) // important colors
	ico.Write(bmpData)

	os.WriteFile("icon.ico", ico.Bytes(), 0644)

	// Build minimal .syso (COFF with RT_GROUP_ICON + RT_ICON resources)
	// Actually, easier to use rsrc or goversioninfo. Let's just output the .ico
	// and use a .rc + windres approach.

	// Write .rc file
	os.WriteFile("resource.rc", []byte("IDI_ICON1 ICON \"icon.ico\"\n"), 0644)

	_ = image.Black // suppress unused import
}
