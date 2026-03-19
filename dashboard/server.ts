import { Database } from "bun:sqlite";
import { resolve } from "path";

const WORKER_DIR = resolve(import.meta.dir, "..");
const DB_PATH = resolve(WORKER_DIR, "worker.db");

function getDb() {
  const { existsSync } = require("fs");
  if (!existsSync(DB_PATH)) return null;
  return new Database(DB_PATH);
}

function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const server = Bun.serve({
  port: 3737,
  async fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/api/dashboard") {
      try {
        const db = getDb();
        if (!db) {
          return jsonResponse({
            tickets: [], subtasks: [],
            stats: { tickets: { total: 0, pending: 0, not_ready: 0, decomposed: 0, needs_intervention: 0, done: 0 },
                     subtasks: { total: 0, pending: 0, in_progress: 0, failed: 0, done: 0 } },
          });
        }

        const tickets = db
          .query(
            `SELECT jira_key, summary, status, worktree_path, base_branch,
                    total_iterations, created_at, updated_at
             FROM tickets ORDER BY updated_at DESC`
          )
          .all();

        const subtasks = db
          .query(
            `SELECT s.id, s.ticket_id, s.description, s.sort_order, s.status,
                    s.spec_model, s.quality_model, s.created_at, s.updated_at
             FROM subtasks s
             ORDER BY s.ticket_id, s.sort_order ASC`
          )
          .all();

        const stats = {
          tickets: {
            total: tickets.length,
            pending: tickets.filter((t: any) => t.status === "pending").length,
            not_ready: tickets.filter((t: any) => t.status === "not_ready").length,
            decomposed: tickets.filter((t: any) => t.status === "decomposed").length,
            needs_intervention: tickets.filter((t: any) => t.status === "needs_intervention").length,
            done: tickets.filter((t: any) => t.status === "done").length,
          },
          subtasks: {
            total: subtasks.length,
            pending: subtasks.filter((s: any) => s.status === "pending").length,
            in_progress: subtasks.filter((s: any) => s.status === "in_progress").length,
            failed: subtasks.filter((s: any) => s.status === "failed").length,
            done: subtasks.filter((s: any) => s.status === "done").length,
          },
        };

        db.close();
        return jsonResponse({ tickets, subtasks, stats });
      } catch (e: any) {
        return jsonResponse({ error: e.message }, 500);
      }
    }

    if (url.pathname === "/" || url.pathname === "/index.html") {
      return new Response(Bun.file(resolve(import.meta.dir, "index.html")));
    }

    return new Response("Not Found", { status: 404 });
  },
});

console.log(`Dashboard running at http://localhost:${server.port}`);
