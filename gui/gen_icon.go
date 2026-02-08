//go:build ignore

package main

import (
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
)

func main() {
	size := 256
	center := float64(size) / 2
	img := image.NewRGBA(image.Rect(0, 0, size, size))

	// 齿轮参数
	outerR := center * 0.85
	innerR := center * 0.55
	holeR := center * 0.25
	teeth := 8
	toothWidth := math.Pi / float64(teeth) * 0.6

	blue := color.RGBA{R: 66, G: 133, B: 244, A: 255}
	white := color.RGBA{R: 255, G: 255, B: 255, A: 255}

	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			dx := float64(x) - center
			dy := float64(y) - center
			dist := math.Sqrt(dx*dx + dy*dy)
			angle := math.Atan2(dy, dx)

			// 齿轮外形
			toothAngle := math.Mod(angle+2*math.Pi, 2*math.Pi/float64(teeth))
			gearR := innerR
			if toothAngle < toothWidth || toothAngle > 2*math.Pi/float64(teeth)-toothWidth {
				gearR = outerR
			}

			if dist <= gearR && dist >= holeR {
				img.Set(x, y, blue)
			} else if dist < holeR {
				img.Set(x, y, white)
			}
		}
	}

	f, _ := os.Create("icon.png")
	defer f.Close()
	png.Encode(f, img)
}
