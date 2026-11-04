// Builds the browser runtime config (dist/config.js) from environment variables.
// Without SUPABASE_URL the app runs as the original browser-local pilot.
// The publishable (anon) key is designed to be public; access is enforced by row-level security
// and the validating database functions. Never put a service-role/secret key here.
function configScript(env=process.env){
  const url=(env.SUPABASE_URL||'').trim(),key=(env.SUPABASE_PUBLISHABLE_KEY||env.SUPABASE_ANON_KEY||'').trim(),workspace=(env.COUNTSCHEDULA_WORKSPACE||'vanderbilt-midwives').trim();
  if(!url)return '// Browser-local pilot mode (no shared backend configured).\nwindow.COUNTSCHEDULA_CONFIG=null;\n';
  if(!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url)&&!/^http:\/\/(localhost|127\.0\.0\.1):\d+$/.test(url))throw Error('SUPABASE_URL must look like https://<project-ref>.supabase.co');
  if(!/^(sb_publishable_[A-Za-z0-9_-]+|eyJ[A-Za-z0-9_.-]+)$/.test(key))throw Error('Set SUPABASE_PUBLISHABLE_KEY (sb_publishable_…) or SUPABASE_ANON_KEY');
  if(/^sb_secret_/.test(key)||/service_role/.test(Buffer.from((key.split('.')[1]||''),'base64').toString()))throw Error('Refusing to publish a secret/service-role key');
  if(!/^[a-z0-9-]{1,64}$/.test(workspace))throw Error('COUNTSCHEDULA_WORKSPACE must be a workspace id');
  return `window.COUNTSCHEDULA_CONFIG=Object.freeze(${JSON.stringify({supabaseUrl:url,supabaseKey:key,workspace})});\n`;
}
module.exports={configScript};
