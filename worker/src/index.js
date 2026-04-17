export default {
	async fetch(request, env) {
		const url = new URL(request.url);

		if (request.method === "POST" && url.pathname === "/update") {
			return handleUpdate(request, env);
		}

		if (request.method !== "GET" && request.method !== "HEAD") {
			return new Response("Method not allowed", { status: 405 });
		}

		if (url.pathname === "/" || url.pathname === "/gitcalver.sh") {
			return handleLatestRedirect(url, env);
		}

		const match = url.pathname.match(/^\/(\d{8}\.[1-9]\d*)\/gitcalver\.sh$/);
		if (match) {
			return handleVersionedFile(match[1], env);
		}

		return new Response("Not found", { status: 404 });
	},
};

async function handleLatestRedirect(url, env) {
	const obj = await env.BUCKET.get("latest");
	if (!obj) {
		return new Response("No version available", { status: 404 });
	}
	const version = (await obj.text()).trim();
	return new Response(null, {
		status: 302,
		headers: {
			Location: `${url.origin}/${version}/gitcalver.sh`,
			"Cache-Control": "public, max-age=300",
		},
	});
}

async function handleVersionedFile(version, env) {
	const obj = await env.BUCKET.get(`${version}/gitcalver.sh`);
	if (!obj) {
		return new Response("Version not found", { status: 404 });
	}
	return new Response(obj.body, {
		headers: {
			"Content-Type": "text/plain; charset=utf-8",
			"Cache-Control": "public, max-age=31536000, immutable",
		},
	});
}

async function handleUpdate(request, env) {
	const auth = request.headers.get("Authorization");
	if (!env.WEBHOOK_SECRET || auth !== `Bearer ${env.WEBHOOK_SECRET}`) {
		return new Response("Forbidden", { status: 403 });
	}

	const { version } = await request.json();
	if (!version || !/^\d{8}\.[1-9]\d*$/.test(version)) {
		return new Response("Invalid version", { status: 400 });
	}

	const resp = await fetch(
		`https://raw.githubusercontent.com/gitcalver/sh/${version}/gitcalver.sh`,
	);
	if (!resp.ok) {
		return new Response("Failed to fetch from GitHub", { status: 502 });
	}

	let script = await resp.text();
	const stamped = script.replace('VERSION=""', `VERSION="${version}"`);
	if (stamped === script) {
		return new Response("VERSION placeholder not found in script", {
			status: 500,
		});
	}

	await env.BUCKET.put(`${version}/gitcalver.sh`, stamped, {
		httpMetadata: { contentType: "text/plain; charset=utf-8" },
	});
	// Update latest only after the versioned file is written, so the
	// redirect never points to a version that doesn't exist yet.
	await env.BUCKET.put("latest", version);

	return new Response(`Deployed ${version}\n`);
}
