# outcome: shout("bob") === "HI BOB!", greet unchanged, both exported
node -e 'const a=require("./app.js"); const ok=a.shout("bob")==="HI BOB!"&&a.shout("Ann Lee")==="HI ANN LEE!"&&a.greet("bob")==="hi bob"&&typeof a.greet==="function"; console.log(JSON.stringify([a.greet("bob"),a.shout("bob")])); process.exit(ok?0:1)'
