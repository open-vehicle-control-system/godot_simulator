---
id: TASK-37
title: 'Use the Generic Sedan as the default car, credited'
status: Done
assignee: []
created_date: '2026-11-15 09:35'
updated_date: '2026-11-15 10:38'
labels: []
dependencies:
  - TASK-36
ordinal: 37000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Replace default_car's placeholder box with "Generic Sedan Car" by Márcio Meireles (MMC Works), https://sketchfab.com/3d-models/generic-sedan-car-58c33766470d46e7b2aed542650494e5, CC BY 4.0. Source files (not committed) in build/sedan_src/ (small.glb 16.7 MB, full.glb 44.8 MB), copied from the user's Downloads. Map its named parts to the simulator's vehicle nodes (Body, Wheel pivots from the wheel objects, Cockpit_* from column-wheel and dashboard parts, the mirror material), set dimensions, driver eye and stereo mount from the model, recompress textures to DDS, keep the committed pack a few MB. Attribution in pack.json (licence CC-BY-4.0), an ATTRIBUTION.md beside the model, README credits; CLAUDE.md, CODE_STYLING.md and the design doc state the one exception to the generated-CC0 defaults.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 default_car shows the sedan, wheels turning and steering, cockpit view from the driver's seat, stereo pair unobstructed by the bonnet
- [x] #2 The credit line, licence and modifications are in pack.json, ATTRIBUTION.md beside the model, and README.md
- [x] #3 The committed pack stays small (target under 10 MB) and the builder regenerates it from the source model
- [x] #4 Before/after captures: chase, side, cockpit, stereo pair
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Model: tools/default_car_model.py builds vehicle.glb from build/sedan_src/small.glb (SHA-256 checked; not committed): Body merged by material (20 materials + Mirror glass fitted on each door mirror's back), Wheel = rear-left tyre + rim + brake disc centred on its axle (rim towards +X), Cockpit_Steer about its column (axis [-0.951, -0.008, 0.310]), origin on the ground midway between the axles; textures downsized (1024 paint/interior, 512 default, 128-256 engine/underbody) as JPEG, PNG where alpha. Godot's runtime glTF reader takes no DDS, hence JPEG/PNG. Measured: wheelbase 2.916 m, track 1.631 m, wheel radius 0.344 m, width 0.257 m, eye [-0.166, 0.411, 1.187] (left-hand drive), stereo mount [0.434, 0, 1.362] behind the windscreen top. Pack 4.7 MB. Without the source, default_packs.py leaves default_car as committed and its tests skip with a message.

Dynamics (priority addition): the old model spun under 0.6 g braking in a turn because both axles kept grip in proportion to load, braking was split by load and stiffness grew linearly with load, so braking made the car oversteer at any margin. DynamicBicycle now has Pacejka B C D E, stiffness ~ load^0.7, friction load sensitivity with lateral load transfer shared by roll stiffness (limit understeer), and a fixed brake bias with the rear held below its load share (proportioning valve/EBD). Every vehicle property moved to vehicle.dynamics (docs/pack_format.md table); --set=PATH=VALUE overrides pack fields per run.
Values (tools/vehicle_dynamics.py): 1350 kg, 60 % front, CG 0.55 m, Iz 0.9 m a b = 2480 kg m2, Cf/Cr = 12.5/22 x axle load per rad (effective, with compliance), C 1.3, E -1.5, exponent 0.7, load sensitivity 0.25, front roll share 0.75, mu 1.0, brakes 70/30 with 5 % margin. Sources: Gillespie, Fundamentals of Vehicle Dynamics ch. 6; Milliken, Race Car Vehicle Dynamics ch. 5, 7, 18; Pacejka, Tyre and Vehicle Dynamics ch. 4; Allen et al. SAE 2003-01-0966 (inertia); ISO 4138, ISO 7975; UN ECE R13-H (braking distribution).
Results (GDScript model, tests in test_dynamic_bicycle.gd): understeer 2.07 deg/g; ISO 7975 60 km/h R50: brake 0.4 g yaw ratio 1.23, sideslip max 1.1 deg; 0.6 g 1.33, 1.5 deg; lift-off 0.25 g at 0.8 g: 1.30, 1.2 deg; steady limit 0.83 g. Overrides: brake_bias_front 0.4 + rear_brake_margin -1: 0.6 g brake -> 39.8 deg sideslip (catchable by steering into it at 0.5 s); bias 0.55, margin -1: 26.5 deg; rear stiffness x0.5: understeer -0.61 deg/g (oversteer), lift-off 6.2 deg.
OVCS1 keeps 48 % front: no weighing found in either repository (a stock Polo 9N3 is ~62 %): to confirm. With the new model either split behaves (48 %: brake 0.6 g yaw ratio 1.40; 62 %: lift-off at its limit 15 deg).
<!-- SECTION:NOTES:END -->
