// Lens distortion in OpenCV's model, as sensors/lens_distortion.gd computes it: where a
// pinhole shows what the lens shows at `seen`, both in focal lengths from the optical axis.
// `radial_tangential` is (k1, k2, p1, p2).
vec2 undistorted(vec2 seen, vec4 radial_tangential, float k3) {
	vec2 pinhole = seen;
	for (int iteration = 0; iteration < 12; iteration++) {
		float r2 = dot(pinhole, pinhole);
		float radial = 1.0 + r2 * (radial_tangential.x + r2 * (radial_tangential.y + r2 * k3));
		vec2 tangential = vec2(
			2.0 * radial_tangential.z * pinhole.x * pinhole.y
				+ radial_tangential.w * (r2 + 2.0 * pinhole.x * pinhole.x),
			radial_tangential.z * (r2 + 2.0 * pinhole.y * pinhole.y)
				+ 2.0 * radial_tangential.w * pinhole.x * pinhole.y);
		pinhole = (seen - tangential) / radial;
	}
	return pinhole;
}

// Where the view drawn for a lens's image holds what the image shows at `image_uv`, both
// from 0 to 1 across. `lens` is (k3, the view's overscan, the image's half width and half
// height in focal lengths).
vec2 drawn_uv(vec2 image_uv, vec4 radial_tangential, vec4 lens) {
	vec2 seen = (image_uv * 2.0 - 1.0) * lens.zw;
	return undistorted(seen, radial_tangential, lens.x) / (lens.zw * lens.y) * 0.5 + 0.5;
}
