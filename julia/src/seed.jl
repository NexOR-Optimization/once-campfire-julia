# Disposable fixture for the experiment; never migrate an existing database.
function seed!(path::AbstractString; messages::Int = 120)
    ispath(path) && throw(ArgumentError("refusing to overwrite an existing database"))
    messages >= 0 || throw(ArgumentError("messages must be nonnegative"))
    db = SQLite.DB(path)
    try
        execute!(db, "PRAGMA journal_mode = WAL")
        schema = (
            """
            CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT,
              role INTEGER DEFAULT 0, status INTEGER DEFAULT 0)
            """,
            """
            CREATE TABLE sessions (id INTEGER PRIMARY KEY, token TEXT UNIQUE,
              user_id INTEGER REFERENCES users(id))
            """,
            """
            CREATE TABLE rooms (id INTEGER PRIMARY KEY, name TEXT, type TEXT,
              messages_count INTEGER DEFAULT 0, updated_at TEXT)
            """,
            """
            CREATE TABLE memberships (user_id INTEGER, room_id INTEGER,
              involvement TEXT DEFAULT 'mentions', connections INTEGER DEFAULT 0,
              unread_at TEXT, updated_at TEXT, PRIMARY KEY(room_id,user_id))
            """,
            """
            CREATE TABLE messages (id INTEGER PRIMARY KEY,
              room_id INTEGER REFERENCES rooms(id), creator_id INTEGER REFERENCES users(id),
              client_message_id TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)
            """,
            "CREATE INDEX messages_room_created ON messages(room_id, created_at)",
            # Rails keeps this counter in SQLite triggers, including foreign writes.
            """
            CREATE TRIGGER messages_ai_rooms_messages_count AFTER INSERT ON messages BEGIN
              UPDATE rooms SET messages_count = messages_count + 1 WHERE id = NEW.room_id;
            END
            """,
            """
            CREATE TRIGGER messages_ad_rooms_messages_count AFTER DELETE ON messages BEGIN
              UPDATE rooms SET messages_count = messages_count - 1 WHERE id = OLD.room_id;
            END
            """,
            """
            CREATE TRIGGER messages_au_rooms_messages_count AFTER UPDATE OF room_id ON messages
            WHEN OLD.room_id IS NOT NEW.room_id BEGIN
              UPDATE rooms SET messages_count = messages_count - 1 WHERE id = OLD.room_id;
              UPDATE rooms SET messages_count = messages_count + 1 WHERE id = NEW.room_id;
            END
            """,
            """
            CREATE TABLE action_text_rich_texts (id INTEGER PRIMARY KEY, name TEXT,
              record_type TEXT, record_id INTEGER, body TEXT, created_at TEXT, updated_at TEXT)
            """,
            "CREATE VIRTUAL TABLE message_search_index USING fts5(body, tokenize=porter)",
        )
        for sql in schema
            execute!(db, sql)
        end
        execute!(db, "INSERT INTO users(id, name) VALUES (1, 'Julia'), (2, 'Reader')")
        token = string(uuid4())
        execute!(db, "INSERT INTO sessions(token,user_id) VALUES (?,1)", (token,))
        execute!(
            db,
            """
            INSERT INTO rooms(id,name,type)
            VALUES (1,'Watercooler','Rooms::Open'), (2,'Private','Rooms::Closed')
            """,
        )
        execute!(db, "INSERT INTO memberships(user_id,room_id) VALUES (1,1), (2,1), (2,2)")
        execute!(db, "BEGIN")
        for id in 1:messages
            # Lexicographically ordered, distinct timestamps for pagination.
            stamp = Dates.format(
                DateTime(2026) + Second(id),
                dateformat"yyyy-mm-dd HH:MM:SS.sss",
            )
            body = "Message $id: coffee, Julia & <friends> — ☕"
            execute!(
                db,
                "INSERT INTO messages VALUES (?,1,1,?,?,?)",
                (id, "fixture-$id", stamp, stamp),
            )
            execute!(
                db,
                "INSERT INTO message_search_index(rowid,body) VALUES (?,?)",
                (id, body),
            )
            b = escape_html!(Buffer(), body)
            execute!(
                db,
                """
                INSERT INTO action_text_rich_texts
                  (name,record_type,record_id,body,created_at,updated_at)
                VALUES ('body','Message',?,?,?,?)
                """,
                (id, String(finish(b)), stamp, stamp),
            )
        end
        execute!(db, "COMMIT")
        return token
    finally
        SQLite.close(db)
    end
end
