// Production build for static hosting (Vercel): writes dist/config.js from environment variables.
const fs=require('node:fs'),path=require('node:path');
const {configScript}=require('./config.cjs');
if(process.env.VERCEL&&!process.env.SUPABASE_URL){console.error('SUPABASE_URL is not set for this Vercel deployment; refusing to deploy browser-local mode.');process.exit(1)}
const out=path.resolve(__dirname,'../dist/config.js');
fs.writeFileSync(out,configScript());
console.log(process.env.SUPABASE_URL?`Wrote shared-workspace config for ${process.env.SUPABASE_URL}`:'Wrote browser-local pilot config');
