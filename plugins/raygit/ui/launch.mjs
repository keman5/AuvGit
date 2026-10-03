// Deep links only select a repository. They never stage, save, or run commands.
export function repoFromLaunchContext(context) {
  const relative = context?.['openai/deepLink']?.url;
  if (typeof relative !== 'string' || !relative.startsWith('/') || relative.startsWith('//') || relative.includes('#')) return null;
  const url = new URL(relative, 'https://raygit.invalid');
  if (url.origin !== 'https://raygit.invalid' || !['/', '/workspace'].includes(url.pathname)) return null;
  const repo = url.searchParams.get('repo');
  return repo?.startsWith('/') && !repo.includes('\0') ? repo : null;
}
