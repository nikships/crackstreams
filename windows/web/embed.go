package web

import "embed"

//go:embed index.html styles.css app.js icon.png vendor/hls.min.js
var Assets embed.FS
