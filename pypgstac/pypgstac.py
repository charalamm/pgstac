import asyncio

import asyncpg
import typer
from smart_open import open

app = typer.Typer()


def pglogger(conn, message):
    print(message)


async def load_ndjson(file: str, table: str, dsn: str = None):
    with open(file, "rb") as f:
        conn = await asyncpg.connect(dsn=dsn)
        async with conn.transaction():
            await conn.execute(f"SET client_min_messages to 'notice'; TRUNCATE {table};")
            conn.add_log_listener(pglogger)
            await conn.copy_to_table(table, source=f,)
        await conn.close()


@app.command()
def load_collections(file: str, dsn: str = None):
    typer.echo(asyncio.run(load_ndjson(file, "collections_staging", dsn)))


@app.command()
def load_items(file: str, dsn: str = None):
    typer.echo(asyncio.run(load_ndjson(file, "items_staging", dsn)))


if __name__ == "__main__":
    app()
