import { existsSync, readFileSync } from 'node:fs';

const configPath = new URL('../../../sites/common_site_config.json', import.meta.url);

let webserver_port: string | number = 8000;
if (existsSync(configPath)) {
	try {
		const common_site_config = JSON.parse(readFileSync(configPath, 'utf8')) as {
			webserver_port?: string | number;
		};
		webserver_port = common_site_config.webserver_port ?? 8000;
	} catch {
		// fall back to default port
	}
}

export default {
	'^/(app|api|assets|files|private)': {
		target: `http://127.0.0.1:${webserver_port}`,
		ws: true,
		router: function (req) {
			const site_name = req.headers?.host?.split(':')[0];
			return `http://${site_name ?? 'localhost'}:${webserver_port}`;
		}
	}
};
