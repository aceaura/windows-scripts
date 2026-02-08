package main

import (
	_ "embed"

	"fyne.io/fyne/v2"
)

//go:embed icon.png
var iconBytes []byte

var appIcon = &fyne.StaticResource{
	StaticName:    "icon.png",
	StaticContent: iconBytes,
}
