# Raster extraction attempts

Mode: built-in `image_gen`, not the CLI fallback. Both outputs were rejected for
edge/negative-space artifacts. Final app resources are SVG reconstructions and
Icon Composer renders; these prompts do not describe the final delivery method.

## Attempt 1

Edit target: the user's `Luminous Sunset E Icon.png`. Transparency requested.

```text
Use case: background-extraction. Asset type: transparent foreground artwork layer for Apple Icon Composer. Input image 1 is the edit target: the supplied Early app icon. Reconstruct ONLY its distinctive lowercase e glyph as a clean alpha cutout. Preserve its exact recognizable ring-like silhouette and open lower-right terminal, the warm ivory/gold upper arch, pale icy blue lower loop and curved horizon seam through its middle. Remove ALL navy tile/background, ALL orange atmospheric glow behind the glyph, the yellow sun inside the hole, white surroundings, baked outer icon bevel, cast shadow, and rounded-square enclosure. The interior negative space and all space outside the letter must be genuinely transparent. Retain the letter's subtle color gradients but no cast shadows or additional glass bevels (Icon Composer will add those). One layer, no panels or text labels. Square 1024x1024 transparent canvas. Center the glyph at x512,y512 with roughly 570px width and 580px height, leaving about 220px clear margins. Do not turn this into a different font or redesign the e. Transparent PNG output.
```

## Attempt 2

Edit target: the first generated cutout. Transparency requested.

```text
Use case: background-extraction / precise-object-edit. This is a cleanup of the supplied isolated Early lowercase e layer. Keep the e silhouette, its warm ivory upper arch, pale ice-blue lower loop, open lower-right terminal and curved middle seam. Output a production-clean transparent PNG with smooth antialiased edges. Remove EVERY isolated speck, yellow/orange residue, white fragment and glow outside the e silhouette and inside its negative space. The two holes/negative spaces must be completely empty alpha=0. No colored dust, no texture, no drop shadow, no background, no sun, no tile, no simulated checkerboard. Flat clean graphic material with the existing ivory-to-blue gradient on the e only. The long upper arch and lower curved loop connect only on the left and through the thin flowing middle bar as shown. Centered square canvas. Do not add anything or alter the letter shape. Genuine transparent background.
```
