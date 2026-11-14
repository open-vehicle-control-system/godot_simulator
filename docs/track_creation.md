---
title: AI-assisted track creation
description: The rules and constraints for building a photorealistic track pack from public geodata, written for an AI assistant and the person reviewing its work.
---

A track pack is built from public data (an airborne LiDAR terrain and surface model, an
orthophoto, OpenStreetMap) by the builders in `tools/`, and rendered by the simulator's shaders.
This guide states what a finished track must look and behave like, the rules the work follows,
and the steps to follow, for a person or any AI assistant. A track is a circuit or a town: an
open-world town map (such as Braine-l'Alleud, streamed in tiles) follows the same rules, its
streets taking the place of the circuit as the roads that matter most. The pack's files are described in
[Pack format](./pack_format.md).

## The goal

The track passes for real footage from a car on that circuit in spring: photorealistic, high
quality and beautiful, at 60 frames per second at 1080p on a mid-range desktop GPU, because the
simulator runs in real time against a vehicle's VMS.

Priorities, highest first:

1. The road: asphalt, lines, kerbs, rubber. The vehicle's cameras look at it all the time.
   Secondary roads (service, access, paddock and public roads) get the same treatment.
2. The ground: terrain shape and surfaces, verges, run-off areas, parking lots.
3. Vegetation, sky, light and atmosphere.
4. Buildings: best effort. They must not break the illusion at driving distance (sensible facade
   textures and colours, roofs from the photo, no glaring artefacts); no more.

## Data is evidence, not truth

Every source has errors: the orthophoto has tile seams, lean, shadows, parked cars and pixel
noise; the LiDAR has gaps and grid steps; OpenStreetMap is approximate. The builders never copy a
source's errors into the world. They fit a clean model the real place would satisfy, and use the
data as evidence for it.

### Terrain

- **No gaps.** Missing LiDAR cells (water, dense vegetation, vehicles, tile seams) are filled by
  interpolating the valid heights around them: no spikes, pits or flat holes.
- **No stairs.** Real altitude changes are smooth. Height quantisation, nearest-neighbour
  sampling, grid aliasing and seams between tiles are removed by smooth resampling and a light
  low-pass filter.
- **Real features stay.** Banks, embankments and kerb edges keep their shape; smoothing never
  turns them into ramps.
- **One surface.** Road and terrain meet with no gap, step or floating edge, and collision is the
  same surface the camera sees.
- **What is drawn solid is solid.** Every mesh that is not ground collides as it is drawn, and
  every tree gets a trunk the vehicle stops against; nothing the camera shows as an obstacle
  may be driven through. The ground collides through each tile's height grid, sampled every
  half metre from the drawn ground (the road where there is one, the terrain elsewhere), so
  the wheels rest on what the camera sees.
  Large forests are tens of thousands of trunks: they go to the physics server as one body, not
  as a scene node each, or loading slows by seconds.
- **Inspect the source mesh, not only the raster.** Terrain exported tile by tile can be flat
  shaded (several vertices per point, normals far apart, so slopes look faceted), leave open
  cracks at tile seams, and keep LiDAR spikes the earlier filtering missed. Rebuild the terrain
  as one welded lattice from the gap-filled, low-passed heights, continuous across tiles, with
  smooth normals.
- **Tuck, then blend.** Under the road, the terrain sits a few centimetres below the road surface
  and blends back to its own heights over a few metres beside it, so neither pokes through the
  other.
- **Watch the seams that tucking creates.** Where two surfaces are centimetres apart, cracks along
  a mesh's strip seams, depth fighting at a distance or shadow acne show as thin dark lines along
  the track. Zoom into captures along the road edges, near and far, before calling a terrain
  change done.
- **A dotted line along the road is not always geometry.** One such line came from the terrain
  shader reading a texture inside a branch: screen-space gradients are undefined along a
  branch's border. Rule the seam out (shadows off, ambient occlusion off) before touching the
  mesh, and compute everything gradient-dependent before any branch.

### Track lines and edges

- **Fitted, not traced.** Lines never follow photo pixels. Per side of the track, one edge line
  is fitted for every metre of the lap, smooth and without a step.
- **The painted line is the evidence, not the asphalt's colour.** A circuit's run-offs, pit
  lane and access roads are paved too, so where the photo's asphalt ends says little about
  where the track does, and an edge fitted to it wanders metres off the real line. The edge
  line is read from its own paint: ground that is thin and lighter than the median across
  it, or the inner rim of lighter ground that carries on outwards (a line against a kerb,
  concrete or a pale verge). The step in lightness places a kerb's border; its blurred
  colours do not. Where the photo shows no paint the line runs just inside the asphalt's end.
- **One course around the lap.** Paint is also grid slots, pit lane lines, kerb stripes and
  run-off artwork. The edge line is the course with the most evidence that moves sideways by
  at most one lateral step per section, each move at a cost: it cannot jump to a mark beside
  it, and carries straight on where the evidence stops.
- **Clean geometry.** Lines are continuous, of constant width and constant inset from the edge,
  and continue across photo tile boundaries and across the start line.
- **Deliberate gaps.** A line stops only where the real track's does (pit entry and exit,
  junctions), detected as stretches with neither paint nor an asphalt end along its course,
  while the course carries on.
- **Kerbs** are snapped to whole stripes: segments start and end on stripe multiples with one
  width each, and short breaks are closed.
- **Racing-line rubber** follows smoothed curvature.
- **One source of truth.** The asphalt's edge is the line's outer side plus a constant inset,
  so asphalt, line and kerb cannot disagree. The simulator draws them in track coordinates (a
  track map: distance along the lap and right of the centreline), on the road mesh and the
  terrain alike, so paint is as sharp as the fit, not as the photo, and does not stop at a
  mesh's edge.
- **Kerb paint is pale.** At 25 cm per pixel red and white stripes blur into pink, green and
  white ones into a pale green lighter than grass: detect those, not saturated red.
- **The line keeps one inset**, kerb or verge beyond it: an inset that differs with and
  without a kerb steps the line sideways at every kerb's end.
- **Precision is part of the model.** What the pack stores per metre is finer than what the
  eye sees from a car: edges and offsets at 1 mm. At 5 cm a line zigzags by centimetres every
  metre.

What made lines discontinuous or misplaced on Mettet and Spa, found by the audit below: edges
fitted to the asphalt's classification instead of the paint (lines off the real one by 0.4 m
on Mettet and 0.8 m on Spa in the median, metres at run-offs); a line inset of 30 cm on a
verge and 4 cm at a kerb (a 26 cm step at every kerb end); 5 cm steps in the stored edges; and
road map texels clamped at a tile's border by the shader (a notch of up to 25 cm where a line
crosses or follows a border). On the roads around the lap: lines moved onto the fitted edge
or centreline, off their own paint; a line's readings rejected against an 80 m median where
the road drifts across its mapped centreline; and markings drawn as a staircase from single
texels where two roads' ground meets in the roads map.

Starting values that worked on Mettet and Spa: lateral steps of 12.5 cm from 2 to 14 m; paint
0.06 lighter (photo luminance) than the median over 1.5 m, at most 62.5 cm wide, or the first
two steps of a lit border; paint beyond the asphalt's end worth 0.4 and the asphalt's end 0.3
of paint within it; 0.05 per sideways step and 0.01 per metre from the centreline; paint
looked for within 30 cm of the course and trusted where 40% of 6 m shows it; a 4 m Gaussian
smoothing; 8 m without evidence for a gap; 1.5 m kerb stripes; a 15 cm line 10 cm in from the
edge. Tune per track, and say so in the pack's recipe.

### Surfaces

- **Classified from the photo.** The orthophoto is classified into surface types (fresh and worn
  asphalt, run-off tarmac, gravel traps, kerbs, painted areas, mown and rough grass, dry patches,
  dirt, forest floor), each rendered with a fitting texture set.
- **Photo far, detail near.** The photo gives the large-scale colour; the texture sets give the
  close-up detail. No visible tiling (rotated or stochastic tiling, macro variation), no
  shimmering (mipmaps, anisotropic filtering).
- **The photo is sunlit and hazy.** Used as colour it is graded into albedo first: its darkest
  colour (0.3rd percentile per channel) is subtracted as haze, a gamma of 0.7 undoes its
  contrast, and a gain per channel brings the track's own asphalt to a neutral albedo of 0.14.
  Classify the graded photo, not the raw one: raw, the haze makes grass bluer than it is green.
  Clamp the result (0.55): painted run-offs otherwise burn out.
- **Classes are benign to confuse when they share a look.** Paved classes take the photo's
  colour fully, so worn asphalt, concrete and paint differ only in grain; vegetation keeps a
  quarter of its texture set's colour and takes the photo blurred over a metre, because the
  photo's pixels are blotches up close.
- **Tell rough from mown grass over metres**, not per pixel: per pixel the split is noise and
  shows as blocky patches.
- **What hides tiling**: each layer read at its own size near the camera, modulated by the same
  set enlarged 5.3 times and turned, fading to that enlarged read and then to the set's mean
  colour with distance, all under the photo's colour.
- **Soft borders, then sharpened.** Layer weights come from the surface map's four nearest
  pixels, raised to a power and jittered by a little noise near the camera: borders are crisp
  and irregular instead of a blurred ramp or a staircase.
- **Colour alone misclassifies.** Leafless woods and waste ground in a spring photo read as
  grey, like asphalt. Use the other sources as evidence: asphalt is smooth, so grey that is
  rough over a few metres is soil-like ground, drawn with the photo's colour.
- **No tree stands on a road.** Trees come from the LiDAR's crown peaks, which fall over the
  asphalt where a crown overhangs a road. A tree whose trunk lies on a drivable surface (the
  track, a secondary road, a parking lot or a paved yard, plus a margin of about half a metre) is
  removed: drawn there it is wrong, and its trunk collider would stop the vehicle on the road.
- **Forest floor is for woodland only.** Ground is forest floor where the LiDAR's tree crowns
  close the canopy (over 55% cover within 4 m). A lone tree stands on what surrounds it: the
  ground under it keeps its class, and the tree's own shadow darkens it.
- **Cars and shadows become soil.** On paved ground, the photo's parked vehicles, objects and
  building shadows are dark or coloured blobs that classify as soil or dirt and smear when drawn.
  Paved areas (car parks, paddocks, roads) take a robust, car-free colour; the blobs' pixels are
  never drawn.
- **OpenStreetMap areas** can confirm or veto a class; the builders read roads and parking
  lots, not land use yet.
- **The photo has no texels on steep faces.** A top-down photo stretches down banks into streaks.
  Above a steepness threshold, fade the photo to its broad colour, switch to a slope material
  (earth, rock, rough grass) and project its texture from the side. Check first that a streak is
  really a steep face and not a misclassification.
- **Grey the photo on asphalt.** Its colour there is mostly chroma fringing and tile tint; real
  tarmac is near neutral.
- **Even out the grain.** Every surface type's texture shows detail at the same scale, so no
  surface (such as run-off tarmac) reads as a blurred photo next to sharp ones.

### Parking lots and secondary roads

They follow the same rule as the track: the photo is evidence for a clean model. The builders
work on a road network and an area, not on a lap: a circuit's builder hands them the roads near
its lap, a town's builder its streets, tile after tile.

- **Parking lots are drawn empty.** Lots are found in OpenStreetMap (`amenity=parking`; their
  parking aisles are the lot's, not roads) and confirmed by the photo: a mapped lot the photo
  shows as grass or wood is left to the ground's classification. Car pixels are never drawn:
  inside its edge a lot is one layer in one colour.
- **A lot's colour is what most of it shows.** The commonest luminance of its pixels, and the
  median colour of the pixels near it: cars, their shadows and paint are the minority and fall
  out. The surface comes from the `surface` tag when there is one, else from that colour: dark
  or mid grey is fresh or worn asphalt, light grey concrete, warm and light gravel, warm and
  dark soil. Pavers cannot be told at 25 cm: only a tag gives them.
- **A lot's edge is fitted, edge by edge.** Each edge of the mapped outline keeps its direction
  and moves to where the photo shows the lot's ground ending, by the median of the readings
  along it; an edge along which the paving carries on, or too short to read, stays as mapped.
  Vegetation the photo shows inside the outline is cut out along a smoothed border, and a lot
  stops at the edge of any road the photo confirms through it. The pack stores the distance to
  the edge, so the edge is as sharp as the fit, not as the map's pixels.
- **Bays are inferred, then drawn clean.** Paint is what is thin and lighter than the ground
  around it. The grid's axes are the directions the paint lines up along; the bay width is the
  spacing the paint keeps (searched between 2.2 and 3.6 m); a row is a band where the paint on
  thin lines across it keeps that rhythm, as far along as the photo shows its dividers and as
  far across as they reach. Rows are found one by one, each with its own phase, from as little
  as 1.5 m of rhythmic paint, then extended over their dividers. Dividers hidden by cars are
  drawn all the same; a line along a row is drawn where the photo shows it. No paint, no bays.
  One direction and one bay width per lot, and bays square to their row: a lot with several
  orientations or angled bays is not modelled yet.
- **A lot is graded.** The LiDAR shows kerbs, parked cars and the gaps between them as creases;
  inside a fitted outline the terrain gives way to its low-pass over a few metres, eased in at
  the edge, so bay lines lie straight. The paint itself is drawn in the lot's own horizontal
  frame, never draped from the photo.
- **Yards are lots the map forgot.** Paved ground on which the photo shows clutter (cars, their
  shadows, stored goods: pixels much lighter or darker than the median around them) over a
  large connected area is drawn like a lot, in the colour of its clear ground, to a smoothed
  border, without bays. Yards keep off the lap and its run-offs, surveyed roads, mapped lots,
  buildings, and a corridor along every mapped way, so a road that was not surveyed keeps
  what the photo shows of it.
- **Secondary roads get the track's treatment.** Service, access, paddock and public roads from
  OpenStreetMap (not tunnels, bridges, driveways or footways) are chained way to way, their
  polyline smoothed into a centreline, and surveyed section by section: the road is the run of
  road-like ground under the mapped line, paint and cars across it ignored. Each side's edge is
  fitted as the track's is; the centreline moves to the middle of the two and the width is one
  smooth value per stretch. A side the photo does not show takes the road's usual width; a road
  the photo does not show at all, or shows as grass, is not drawn.
- **Their surface follows the photo**: the `surface` tag or the colour, as for lots; concrete is
  laid in slabs whose joints are drawn. A road keeps its colour lane by lane, as the median
  along it: a cycle path or wheel tracks stay, cars, shadows and tile seams do not.
- **Road markings are respected, realistic and continuous, on every road.** Draw the markings the
  photo actually shows, not a generic template. A line is found wherever paint keeps to one
  offset along the road, at any offset: its course is followed window by window (it may move
  1 m sideways between two windows 12.5 m apart: a mapped centreline is a rough polyline, and
  the road drifts across it), smoothed over 5 m, and kept. It is not
  moved onto the road's fitted edge or centreline: those come from the photo's classification,
  the line from its own paint, and a line moved onto them lands beside the real one where
  the paving carries on past it. It is solid, or dashed to the national standard
  its rhythm in the photo is closest to, in phase with the distance along the road; paint
  without a rhythm is a worn solid line if dense, else nothing. A road reaches at least past
  the lines painted on it. A short bar across a lane is a stop line only before a junction.
  A light band across a road is not a pedestrian crossing: at 25 cm per pixel its stripes
  cannot be told from sunlit ground between two shadows, a pale patch or a car, and every
  band drawn as one on Mettet and Spa was one of those. Crossings come from the map
  (a tagged crossing node), one per node. Lines stop only where another road
  joins (the edge line of the through road over the joining road's mouth, every line of the
  joining road over the through road's width) or where the photo stops showing them for more
  than a dozen metres. Paint is slightly worn and rough, never pure white or glossy.
- **One source of truth here too.** Surface, colour and paint come from the same fitted
  centreline and edges, drawn in road coordinates on the terrain.
- **A double line is paint too wide for one.** Paint over 60 cm wide in the photo, and much
  lighter than the lanes beside it, is drawn as two lines a line's width apart.
- **Know what the photo cannot give.** At 25 cm per pixel an arrow is a blob four pixels wide
  whose kind (ahead, left, right) cannot be read, hatching is a grey smear and give-way teeth
  are a broken bar: they are not drawn rather than drawn wrong, and the road shows clean
  asphalt there. They need sharper imagery or a mapped source (`turn:lanes`). Say so in the
  pack's recipe.
- **One zebra crossing per real crossing.** Several OpenStreetMap nodes or ways often describe
  one crossing (both directions, a footway and a node): merge them before drawing. A crossing
  spans the carriageway across it, its stripes parallel to the road's axis at the region's sizes
  (Belgium: 0.5 m stripes and gaps), and only on the road; its sign comes from the same merged
  crossing, so the two agree one to one.
- **Traffic lights and road signs come from the data and follow the region**, on every public
  road: the streets of a town map, and the roads around a circuit (the circuit itself and its
  service roads get only what is tagged on them). A builder step takes the surveyed roads and
  an area's OpenStreetMap extract, tile after tile. Two kinds of evidence, and the pack says
  of every sign which it is:
  - *Tagged*: `highway=traffic_signals` (a head for every approach of a junction, at its stop
    line), `stop`, `give_way`, `crossing` and `traffic_sign=*` nodes, their `direction`
    (`forward`, `backward`, a compass bearing for a sign mapped beside the road) respected.
    A stop or give-way without a direction governs the traffic heading for the nearer end of
    its way.
  - *Derived*, what the data implies under the region's highway code and nothing more: a
    speed limit sign where `maxspeed` changes, a little into the new limit, on the right
    for the traffic entering it and on the left too of a one-way (a way without a plain
    `maxspeed` implies nothing); a stop
    sign at a stop line the road builder drew across a lane before a road of at least that
    road's rank; a give-way sign over a roundabout sign at every public way into a
    `junction=roundabout`; a pedestrian crossing sign each way at every zebra crossing
    drawn. A tagged sign replaces the derived one for the same traffic within 12 m.
  - A tagged node off the surveyed roads or off the terrain, and a sign code no face is
    drawn for, are reported by the builder, not placed by guess.
- **Signs stand as the region stands them.** For Belgium (Vienna convention), from the
  arrêté ministériel of 11 October 1976 on the minimum dimensions and placement of road
  signs, as Wallonia consolidates it (wallex.wallonie.be, act 1176):
  - Side and facing (art. 1.4): right of the carriageway in the direction of travel, facing
    the traffic they govern; turned 5° away from the road against glare (practice, not in
    the rule). Stop and give-way signs stand at their line (art. 8.1, 8.3). A speed limit is
    repeated on the left only of a one-way carriageway (art. 9.9 asks it of the 50 km/h
    reminder there; no rule asks it on a two-way road).
  - Clearance (art. 1.3): the plate's near side 0.5 m from the fitted edge outside built-up
    areas (the minimum; 0.3 m inside).
  - Height (art. 1.3, as amended on 30 June 2020): the lower edge 1 m above the ground on a
    verge outside built-up areas where nobody walks or parks, and 2.2 m (the minimum
    elsewhere) where people walk: a limit of 50 km/h or less, an urban `maxspeed:type`, a
    `sidewalk` tag, or paved ground beside the road. Signs put up before 2020 often stand
    higher on verges.
  - Plate sizes (art. 6.4.1 and 6.4.2, minimum, read in the text of the version in force
    from 2014 to 2020; the current version gives its tables as images): outside built-up
    areas on a road of under four lanes, triangles of 0.9 m, the octagon 0.9 m across, discs
    of 0.7 m; inside them (a limit of 50 km/h or less), triangles of 0.7 m, the octagon
    0.9 m, discs of 0.6 m; squares on their point 0.4 m; the crossing sign F49 0.6 m square
    (art. 12.13). Roads of four lanes and more, and motorways, take larger plates the
    builder does not draw yet.
  - Posts of 76 mm galvanised tube (trade size, not in the rule). Signal heads of three
    200 mm lenses (art. 3.2 asks at least 180 mm), their lower edge 2.3 m up (2.2 m at
    least, art. 1.3) on a 114 mm pole, on a black backplate edged in white (practice).
- **Nothing stands on what is driven on.** A sign moves back along its road, up to 12 m,
  until its post is off every other road, the lap, the lots and the buildings, and on the
  terrain; with no free ground it is reported and not placed. Trees follow the same rule:
  a LiDAR crown peak over asphalt is a crown overhanging a road, so a tree whose trunk is
  on the lap, a surveyed road, a lot or a yard, or within 0.5 m of their edge, is dropped.
- **Markings agree with signs.** The road builder's stop lines and crossings are reused: a
  sign stands at the marking drawn within 10 m of it. A tagged stop or signal without a
  line gets one across its lane, a tagged zebra crossing the photo does not show is drawn,
  and a stop line drawn where a give-way sign stands becomes a give-way line of triangles
  (the photo shows the triangles as a broken bar). A give-way sign without any line drawn
  gets none yet.
- **Sign faces are drawn by the builder** from the published designs (shapes, colours, a
  stroke alphabet for digits and STOP), never copied from an artwork file, and credited in
  the pack. A code without a drawn face is not placed.

Starting values that worked on Mettet and Spa. Roads: sections every metre on a centreline
smoothed over 3 m; edges looked for 6 m beyond the road's usual half width (3.5 m primary down
to 2 m service, 1.5 m track); breaks under 1 m ignored; the track's fit (80 m median, 0.75 m
outliers, 10 m smoothing), then a 60 m median and 15 m smoothing of the width; 30% of a road's
length with an edge to confirm it; colour in 16 lanes, a 30 m median along. Markings: paint is
0.06 lighter (photo luminance, not albedo: the grade flattens highlights) than the median over
1 m across for lines and over 15 m along for stop lines; lines read in 25 m windows, 13% of a
window painted to exist and 75% to be solid; Belgian dashes 2.5 m with 10 m or 5 m gaps, 5 m
with 2.5 m, 1.25 m with 1.25 m; lines 15 cm wide, a road reaching 30 cm past its lines;
crossings 4 m long across the road, stripes 50 cm. Lots: half of the outline's ground made to
confirm it; edges moved by up to 4 m; paint 0.035 lighter than its surroundings and under
three pixels wide; bay lines 12 cm; rows 3 to 12 m deep with at least three dividers shown;
terrain low-passed over 4 m inside a lot, eased in over 2 m. Yards: clutter is 0.12 lighter or
darker than the median over 9 m, read at 1 m per pixel; a yard has 12% clutter and 75% made
ground within 4 m, covers at least 300 m2 and keeps 7 m from mapped ways. Double lines: paint
60 cm wide and 0.12 lighter than the median over 2 m. Signs: public roads followed to 450 m
from the lap (service roads 250 m); a mapped point snapped to a surveyed road within 8 m; a
speed limit sign 5 m into its stretch, none for a stretch under 30 m; a lane's stop line
starts within 1 m of the centreline and ends within 1.5 m of the edge.

### Decals

A driven road is not clean: rubber, stains and patches show it is used. They are decals the
builder places where the data is evidence for them, never scattered for effect, and few.

- **Tyre marks where cars brake hard.** A speed profile of the lap (corners taken at the grip a
  car has, braked into and accelerated out of) gives its braking zones; each zone that sheds
  enough speed gets one to three marks on the racing line towards its end, a car's two tracks
  wide. Where the photo shows a dark streak along the lap, narrower than a car and too short
  to be the racing line's rubber, marks follow it instead.
- **Stains and patches where the photo shows them.** A small blot darker than the asphalt
  around it is an oil stain, a wide squarish one patched asphalt. Not a stain: a blot on the
  racing line (its rubber, which the road already draws), one darker than a stain can be or
  beside a shadow's dark core (a shadow), beside paint (the dark fringe the photo leaves around
  it), coloured (a car), or where a tree or a building can cast its shadow.
- **Covers where the map tags them.** A manhole or a drain only from a tagged node
  (`man_made=manhole`, `manhole=*`) on a road; at 25 cm per pixel the photo cannot show one.
- **On the asphalt, clear of the paint.** A decal keeps 25 cm from the edge lines and lies on
  the ground only: it is projected onto what the terrain surface draws and nothing else.
- **The textures are drawn by the builder** and credited in the pack.

Starting values that worked on Mettet and Spa: 12 m/s2 of grip and braking, 4 m/s2 of
acceleration, 75 m/s at most; a zone sheds 16 m/s or more, a mark per 20 m/s, 6 to 14 m long,
within 35 cm of the racing line, over the last two thirds of the zone. Blots 0.03 darker than
the median albedo (0.035 for a stain or a patch, at most 0.08), saturation under 0.2, at
least 0.4 m2; a stain under 2.5 m, a patch 1.5 to 6 m a side; a streak 4 to 30 m long, under
2.5 m wide, three times longer than wide. 15 m between two decals of one kind; drawn up to
120 m away.

### Buildings and roofs

Buildings are best effort, but roofs are seen from above in the photo and from the road at
driving distance, so they follow the same rule as the ground: the photo is evidence, not the
texture.

- **Classify each roof** from its colour in the graded photo and its LiDAR shape: dark slate,
  red or orange clay tiles, brown or grey concrete tiles, profiled metal sheet, flat bitumen,
  flat gravel, green roof. Shape decides what colour cannot: a roof under 8 degrees carries no
  tiles, and a roof over 350 m2 pitched under 20 degrees is sheeting unless it is red. Glass,
  skylights and solar panels are not told apart yet.
- **One colour per roof, read where the photo can be trusted.** The photo's roofs lean and one
  side of a pitched roof is shaded: the colour is the median of the brightest half of the
  pixels at least 1.5 m inside the outline, clamped (0.3) because sheeting burns out in the
  photo. A colour per face would bake the photo's sun into the albedo.
- **Draw a matching texture, tinted to that colour.** Each class gets a fitting CC0 roof texture
  set, divided by its mean and multiplied by the roof's colour, so it reads like the photo from
  above and has real detail up close. The photo's own pixels are never drawn on a roof.
- **Orient the texture to the roof.** Tile rows run parallel to the eave, at real-world scale,
  the image's top up the slope; a sheet's corrugations run down the slope, as they are laid.
  Texture coordinates are metres along the eave and up the slope.
- **Build each building from its footprint alone, closed by construction.** The roof is a
  set of triangles covering the footprint exactly; a wall hangs from every edge of the roof's
  outline, and the floor is the roof's triangles turned over. Walls, roof and floor share
  their edges, so nothing can open between them whatever the roof's shape, and a gable's end
  is a wall. Never fit a roof and walls apart and patch the gap: moving a roof onto a fitted
  plane while the walls kept their own tops left 105 of Spa's 158 buildings and 163 of
  Mettet's 203 open (gable ends, slits under the eaves).
- **Clean and square the footprint first** (`tools/footprints.py`): points mapped twice and
  points along a straight wall go, a loop where the outline crosses itself is cut off, the
  ring runs counter-clockwise, courtyards are kept as holes. Jitter under 0.2 m along a wall
  goes (Douglas-Peucker), and a wall within 15 degrees of the footprint's main direction, or
  of its perpendicular, turns about its middle onto it. No wall moves more than 0.4 m from
  where it is mapped: a footprint that squaring would move further is only straightened, or
  kept. Two buildings sharing a wall are squared each on its own and may part by that much:
  keep the tolerance under what shows.
- **Walls go below the lowest ground under the building** (0.5 m under the lowest terrain
  point inside the footprint, not only at its corners), up to the roof.
- **Roof shapes come from the same outline**: flat, a skillion (one plane), a hip (the
  footprint's straight skeleton, `tools/straight_skeleton.py`), a gable (the hip's ridges run
  out to the end walls, where two walls run back from an end; else one ridge along or across
  the footprint) and a pyramid. The skeleton checks its own result (each face a plane rising
  from its wall, the faces covering the footprint) and refuses a footprint it gets wrong.
- **The LiDAR chooses the shape**, unless the map names one (`roof:shape`): each shape's
  eave height and slope are fitted to the surface model inside the footprint (0.7 m from its
  edge, a point 1.5 m off the fit being a tree or a chimney), and the best fit wins. A shape
  must beat a flat roof by its prior (5 to 10 cm RMS) and rise 0.6 m; a skillion rises no
  more than 5 m (more is two roofs, or a roof under trees); a roof under 25 m2 is flat. No
  wall is lower than 2.2 m. A building the LiDAR does not show (under 1.5 m) is newer than
  the survey: it takes the map's `height`, or 3 m a level, or one storey, and the map's roof
  shape or a flat roof.
- **Check every building is a closed solid**, in the builder and in the tiles
  (`python3 tools/buildings.py PACK/tiles`): no triangle without an area, every edge in
  exactly two triangles running opposite ways, the faces wound outwards (a wall wound inwards
  is culled and looks missing). A faulty shape is dropped and the others fitted again, down
  to a flat roof, then without its courtyards, then as a box over its bounding rectangle.
- **A dark trim along the roof's edge** stands for gutters and flashing. It needs the
  distance to the edge as a plane over each triangle: a roof of a few large triangles has
  every vertex on its edge, and a distance per vertex would paint it all as trim.
- **Facades** use a texture set per kind (brick, plaster, stone, corrugated metal, concrete)
  and dirt at the foot; clean concrete, not rust-stained, for barriers and concrete walls. A
  building keeps the kind the experiment gave it. Windows are laid out per wall, from its
  corner and its ground floor (the ground at its higher end, at most 1.5 m above its lower
  end): bays centred on the wall so no window is cut by a corner, rows a storey apart
  (3 m, offices 3.6 m) as far as the wall's top allows, which gives a gable its attic
  window; a door at ground level on two walls in five. A hall has a band of glazing under
  the eaves, not on a sloping gable top, and a sectional door on long walls.

### Trees, distance and haze

- **Measure before cutting anything.** What a forest costs is not where it seems: on Spa the
  trees took 7 to 9.5 ms of a 17 ms frame, 6 to 8 of them in the shadow maps, 1 to 1.5 in
  the picture itself, and drawing them half as far saved 0.5 ms. `--timing` prints what
  the GPU spends on every viewport, where it spent the most, and what was drawn; compare with
  the same pack without its `trees`.
- **A shadow map takes plain triangles, not cut-outs.** A tree is drawn as cards cut out by
  their texture; into a shadow map (four cascades, once per viewport: the window and each
  stereo camera) that costs many times what the same shape costs as triangles. The simulator
  casts a tree's shadow from the silhouette of its cards, cut into rectangles from the atlas's
  alpha; the cards cast none. Anything else drawn by the thousand with a cut-out texture gets
  the same treatment.
- **A cut-out does not reflect the sky** (`SPECULAR = 0.0`). Godot looks the sky's radiance up
  with implicit screen-space derivatives, which are undefined beside a pixel the alpha scissor
  discards: the cards' edges changed by 1/255 from frame to frame, a few hundred pixels in every
  viewport, so no two stereo frames of a still view were identical. Leaves at that scale
  reflect nothing visible anyway. `tests/rendered/test_still_view.gd` guards it.
- **Trees are batched by cluster**, 64 m wide, per impostor: what is behind the camera, beyond
  the draw distance or outside a shadow cascade is not sent to the GPU.
- **Each kind of thing has a draw distance and fades at its end**, never pops. Trees are drawn
  up to the pack's `trees.canopy.from_m` and shrink to their foot over its last fifth, into
  the canopy already standing there: no pixel pattern, which a camera would see as noise.
  Choose it where a tree is a few pixels wide and woods read as a mass: 600 m on Spa. Open
  country with lone trees wants more, since a lone tree has no canopy to become.
- **Beyond it the woods are a canopy**: one coarse surface over the crowns (a vertex every
  8 m, held up by the trees within 10 m, hanging to the ground at the woods' edge). It must
  read as many crowns, not as a green mass: its colour is the impostors' crowns' (so no line
  shows where it takes over), lighter and darker as the orthophoto shows the woods from
  above, with round crowns lit on their sunny side and shaded gaps between them; each vertex
  stands up to 2.5 m above or under the surface, so the woods' outline against the sky is
  jagged. It lies under the ground near the camera and rises among the last trees drawn,
  before they shrink, so nothing appears at once. It covers the whole track, so the woods
  beyond the loaded tiles stand on the far terrain. `tools/track_tiles.py` writes it from
  the trees the tiles list.
- **Haze is the air, not a curtain.** The pack gives the meteorological visibility
  (`haze.visibility_m`): how far a black object keeps 2% of its contrast. The fog takes the
  sky's colour in the direction looked at. A light spring haze is 10 to 20 km; at 16 km
  something 100 m away keeps 97.6% of its contrast and a hill 1 km away 78%. The cameras feed
  OVCS's vision: nothing within 100 m may lose more than 5% (visibility under 8 km does).
  Haze does not hide a draw distance; the canopy does.
- **Check the stereo cameras' own image** before and after (`--stereo-record`): the road, its
  lines and the shadows across it must be as they were.

## Content and licences

- **The simulator ships no content.** Shaders and material logic live in `simulator/`; textures,
  surface maps and track data belong to the pack and are named in its `pack.json`.
- **Packs are data**, never code, and are released on their own.
- **Only redistributable sources.** CC0 texture sets (Poly Haven, ambientCG), each credited in
  the pack's `attribution`. Geodata keeps its licence: the Wallonia LiDAR and orthophotos are
  CC-BY 4.0, OpenStreetMap is ODbL 1.0, so a track pack built from them is
  `CC-BY-4.0 AND ODbL-1.0`. Nothing without a licence that allows redistribution goes into a pack
  meant for release.
- **Every track is tiled**, circuits as well as towns: the pack holds tiles (each with its meshes,
  ground maps, collision and objects) and a coarse far terrain, and the simulator loads only the
  tiles near the vehicle. Builders cut terrain, roads and maps on tile edges without seams, and
  assign each mesh and object to one tile.
- **Build time, not load time.** Smoothing, fitting and classification happen in the builders in
  `tools/`; the simulator only draws what the pack contains.
- **Generated files are not committed**; a pack's directory under `packs/` holds its manifest,
  licence and the commands that build it.

## Verifying the work

- **Logic is tested first**, headless: fitting, classification, gap filling and pack parsing get
  a failing test before the code ([Testing](./testing.md)).
- **Looks are judged on captures.** `--spawn=X,Y,Z,YAW_DEG` places the car, `--eye=X,Y,Z` looks
  at it from a fixed point (for views from above) and `--screenshot=FILE` saves the window. Every change that affects the look gets a before and an
  after capture from the same viewpoint, numbered in order, shared as the work goes.
- **Capture every "before" first, and keep the untouched pack.** Take the task's before
  captures before changing anything, and keep a copy of the pack as it was, so a fair before can
  be retaken from any viewpoint found later.
- **Critique your own captures** against reality: would this pass for a photo? Name what still
  looks wrong.
- **Zoom in.** Thin artefacts (dark seam lines, aliasing, a line that wobbles) are invisible at
  full-frame size. Inspect crops of the road edges, kerbs and slopes at two or more times, near
  and far, after every geometry or shader change.
- **Find the cause before fixing a look.** A visual flaw is reproduced up close and far, its
  cause identified (classification, geometry, depth, shading), then fixed at that cause.
- **Check lines along their whole length, not at spot views.** A handful of viewpoints misses
  most of a lap. `python3 tools/line_audit.py EXPERIMENT_DIR PACKS_DIR TRACK OUT_DIR` reads the
  pack as the simulator does (track map, roads map, lines images, the shader's blending of
  map texels) and, for every metre of the lap's two edge lines and of every line of every road:
  whether paint is drawn, how far it is from the line the photo shows, how far it steps
  sideways off its smooth course, and whether it lies on the verge. It reports gaps over a line
  the photo shows (3 m or more), lines over 0.3 m off the photo's, sideways steps over 5 cm,
  lines drawn where the photo shows none, and every pedestrian crossing with what supports
  it (a map node, paint), its size, how much of it is drawn and paved, and its duplicates
  within 12 m. It writes the lap and the roads unrolled over the photo and over its
  classification with the paint and the defects marked, an overview from above and crops at
  the worst defects. Run it on the untouched pack first and after every change to a fit, an
  encoding or the terrain shader; a line is done when the audit is clean or every defect left
  is explained.
- **A still view draws the same pixels every frame.** Stand still in the woods with
  `--hold=0,0 --stereo-record=DIR` and compare the last frames: any pixel that changes is a
  shader reading gradients beside a discard or a branch (see Terrain and Trees above).
- **Look from above too.** A high view over the area shows what the road hides: patches under
  lone trees, smeared photo around buildings and in car parks, roofs that do not match the photo.
- **Measure the frame time** at 1080p; the budget is 16.7 ms per frame for everything.
  `--timing` reports the GPU's time over all viewports, the stereo pair included, with the
  draw calls and primitives; the GPU slows its clock under a frame cap, so compare runs at
  the same frame rate.
- **Measure the start and the streaming.** `--timing` prints when the first frame was drawn
  (the budget is 3 s from the process's start) and, every five seconds, the worst frame and
  how many ran over 33 ms. Drive a whole lap with the stereo pair on: tiles enter and leave
  all along it.
- **Look at the tiles' edges.** Take captures up close where the road and the terrain cross a
  tile's edge, and where four tiles meet: no crack, step or change of colour may show there.
  A view from high above shows which tiles are loaded and where the far terrain takes over.
- **A reviewer other than the author** looks at the captures and the code before the pack is
  released.

## Steps

1. **Start from a backlog task** with acceptance criteria; name the track and its sources.
2. **Gather the sources** for the track's area: LiDAR terrain model (and surface model for
   buildings and trees), orthophoto tiles, OpenStreetMap extract. Note each licence for the
   pack's `attribution`.
3. **Capture a baseline** at fixed viewpoints (`--spawn`, `--screenshot`), numbered
   `01_<track>_baseline.png`: along the lap in the chase view and the stereo camera's view, plus
   a car park, a secondary road, the main buildings, and one high view looking down over the
   area.
4. **Fix the geometry first**, in the builders in `tools/`, test first: fill LiDAR gaps and
   remove stairs and seams; fit the track's edges and derive the asphalt's extent, lines, kerbs
   and racing line from them; fit the secondary roads' centrelines and edges and the parking
   lots' outlines and bay grids the same way; make roads and terrain one surface, collision
   included.
5. **Then the surfaces**: classify the orthophoto, choose a CC0 texture set per surface type,
   blend photo colour far with texture detail near; give roads and parking lots the surface the
   photo shows, with parked cars removed.
6. **Then light and atmosphere**, then vegetation, then buildings and roofs (best effort).
7. **After every visible change**, capture the same viewpoints, number the capture, share it
   with one line on what changed, and critique it against reality.
8. **Cut the tiles** (`tools/track_tiles.py`) from the finished world and keep the budgets:
   the frame time at 1080p, the start time and the frames while tiles stream (`--timing`).
9. **Finish**: run the checks (format, lint, tests), update the pack's recipe and attribution
   and the docs the change touches, and report what changed, the frame time, the before/after
   captures and what still looks wrong. Do not commit until the change is validated.

## Never

- Trace a source's errors into the world (wobbling lines, holes, stairs, tile seams).
- Put textures, track names or track data in `simulator/`.
- Use an asset whose licence does not allow redistribution in a pack meant for release.
- Smooth, fit or classify at load time: the simulator only draws what the pack holds.
- Classify surfaces from photo colour alone, or let the photo stretch down a steep face.
- Call a geometry change done without zooming into captures along the road edges.
- Draw a roof with the photo's own pixels: classify it, pick a matching texture and tint it.
- Draw parked cars from the photo, or a road or parking line that wobbles with the photo.
- Draw a marking the photo cannot resolve from a guess of its shape.
- Place a sign or a signal no tag and no rule of the highway code implies, or stand anything
  (a sign, a pole, a tree) on ground that is driven on.
