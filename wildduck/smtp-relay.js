const SMTPServer = require('smtp-server').SMTPServer;
const nodemailer = require('nodemailer');
const fs = require('fs');

const WILDDUCK_API_URL = process.env.WILDDUCK_API_URL || 'http://wildduck:8080';
const WILDDUCK_API_KEY = process.env.WILDDUCK_API_KEY;
const MAILJET_HOST = process.env.MAILJET_HOST || 'in-v3.mailjet.com';
const MAILJET_USER = process.env.MAILJET_USER;
const MAILJET_PASS = process.env.MAILJET_PASS;

// Leer certificados TLS de la VM
const tlsOptions = {
    key: fs.readFileSync(process.env.TLS_KEY_PATH || '/tls/tls.key'),
    cert: fs.readFileSync(process.env.TLS_CERT_PATH || '/tls/tls.crt')
};

const server = new SMTPServer({
    secure: false, // Usar STARTTLS
    key: tlsOptions.key,
    cert: tlsOptions.cert,
    authOptional: false, // Forzar autenticación
    logger: true, // Habilitar logs detallados de la conexión SMTP para depuración
    
    // Autenticar contra la API de WildDuck
    async onAuth(auth, session, callback) {
        try {
            console.log(`[onAuth] Intentando autenticar usuario: ${auth.username}`);
            const res = await fetch(`${WILDDUCK_API_URL}/authenticate`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-Wildduck-Key': WILDDUCK_API_KEY
                },
                body: JSON.stringify({
                    username: auth.username,
                    password: auth.password,
                    scope: 'smtp'
                })
            });
            const text = await res.text();
            console.log(`[onAuth] Respuesta de WildDuck API (status: ${res.status}):`, text);
            
            let data;
            try { data = JSON.parse(text); } catch(e) {}

            if (res.ok && data && (data.status === 'ok' || data.user || data.success)) {
                session.userEmail = auth.username;
                return callback(null, { user: auth.username });
            }
            return callback(new Error('Authentication failed'));
        } catch (err) {
            console.error('[onAuth] Error de conexión con API:', err);
            return callback(new Error('Authentication service temporarily unavailable'));
        }
    },
    
    // Recibir y reenviar el flujo de correo a Mailjet
    onData(stream, session, callback) {
        const mailjetTransporter = nodemailer.createTransport({
            host: MAILJET_HOST,
            port: 587,
            secure: false, // STARTTLS
            auth: {
                user: MAILJET_USER,
                pass: MAILJET_PASS
            }
        });
        
        // Reenviar el stream MIME original a Mailjet
        mailjetTransporter.sendMail({
            raw: stream
        }, (err, info) => {
            if (err) {
                console.error('Relay error:', err);
                return callback(new Error('Failed to relay message'));
            }
            console.log('Email enviado por:', session.userEmail, info.messageId);
            return callback(null);
        });
    }
});

const port = process.env.PORT || 587;
server.listen(port, '0.0.0.0', () => {
    console.log(`SMTP Relay escuchando en el puerto ${port}`);
});
