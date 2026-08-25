/**
 * renovate-config.js
 *
 * Grouping strategy:
 *   - Each ecosystem gets ONE PR per update type (patch / minor / major)
 *   - Everything not in a named ecosystem → one catch-all PR per manager per update type
 *   - Dockerfile → one PR per update type, separate branch prefix
 *
 * Result: max ~15 PRs total instead of one per package
 */

const reviewerData = require('./renovate-reviewers.json');


// ── Builds 3 packageRules (patch/minor/major) for one ecosystem group ────────
function ecosystemGroup({ matchPackageNames, matchPackagePatterns, matchManagers, groupBaseName, extraLabels = [] }) {
  return ['patch', 'minor', 'major'].map(type => {
    const rule = {
      matchUpdateTypes   : [type],
      groupName          : `${groupBaseName} ${type}`,
      separateMinorPatch : false,
      separateMajorMinor : false,
      automerge          : false,
      prCreation         : 'immediate',
      labels             : [type, ...extraLabels]
    };
    if (matchPackageNames)    rule.matchPackageNames    = matchPackageNames;
    if (matchPackagePatterns) rule.matchPackagePatterns = matchPackagePatterns;
    if (matchManagers)        rule.matchManagers        = matchManagers;
    return rule;
  });
}

// ── All named packages per manager (used to exclude from catch-all) ──────────
const PIP_ECOSYSTEM_PACKAGES = [
  'langchain', 'langchain-core', 'langchain-community', 'langchain-openai',
  'langchain-anthropic', 'langchain-google-genai', 'langchain-google-vertexai',
  'openai', 'anthropic', 'tiktoken',
  'transformers', 'tokenizers', 'datasets', 'accelerate', 'torch',
  'sentence-transformers', 'huggingface-hub',
  'boto3', 'botocore', 's3transfer',
  'fastapi', 'uvicorn', 'starlette', 'pydantic', 'pydantic-core',
  'requests', 'httpx', 'aiohttp', 'urllib3', 'certifi',
  'flask', 'flask-cors', 'gunicorn',
  'pandas', 'numpy', 'scikit-learn', 'nltk',
  'pymupdf', 'python-docx', 'docx2txt', 'mammoth', 'pillow', 'openpyxl',
  'pymongo', 'aiofiles'
];

const NPM_ECOSYSTEM_PACKAGES = [
  'react', 'react-dom', '@types/react', '@types/react-dom',
  'react-router', 'react-router-dom',
  '@reduxjs/toolkit', 'react-redux',
  'vite', '@vitejs/plugin-react',
  'typescript', 'eslint', '@eslint/js',
  '@typescript-eslint/eslint-plugin', '@typescript-eslint/parser',
  '@typescript-eslint/type-utils', '@typescript-eslint/utils',
  'typescript-eslint', 'eslint-plugin-react-hooks', 'eslint-plugin-react-refresh',
  'tailwindcss', '@tailwindcss/vite',
  '@mui/material', '@mui/icons-material', '@emotion/react', '@emotion/styled',
  '@headlessui/react', '@heroicons/react',
  'react-hook-form', 'axios', 'jspdf', 'jspdf-autotable', 'husky', 'prettier'
];

const MAVEN_ECOSYSTEM_PACKAGES = [
  'org.springframework:spring-framework-bom',
  'org.springframework.boot:spring-boot-starter-data-mongodb',
  'com.auth0:java-jwt', 'io.jsonwebtoken:jjwt-api',
  'io.jsonwebtoken:jjwt-impl', 'io.jsonwebtoken:jjwt-jackson',
  'io.netty:netty-bom',
  'org.projectlombok:lombok', 'org.modelmapper:modelmapper',
  'commons-fileupload:commons-fileupload',
  'io.opentelemetry:opentelemetry-exporter-otlp'
];

const MAVEN_ECOSYSTEM_PATTERNS = [
  '^org\\.springframework\\.boot:spring-boot-starter',
  '^org\\.springframework\\.boot:spring-boot-maven-plugin',
  '^org\\.springframework\\.security',
  '^org\\.apache\\.tomcat'
];

module.exports = {

  // ── Platform ──────────────────────────────────────────────────────────────
  platform : 'gitlab',
  endpoint : 'https://gitlab.example.com/api/v4/', // replace with your GitLab instance URL

  // ── Repo discovery ────────────────────────────────────────────────────────
  onboarding    : false,
  requireConfig : 'ignored',
  repositories: [
    'your repo path here'
  ],

  baseBranches: ['develop'],

  // ── Presets ───────────────────────────────────────────────────────────────
  extends: ['config:recommended', ':semanticCommits'],

  // ── 🔥 CRITICAL: Disable Renovate artifact + pipeline behavior ─────────────
  ignoreTests  : true,
  updateLockFiles: false,
  // ── Dependency dashboard ──────────────────────────────────────────────────
  dependencyDashboard         : true,
  dependencyDashboardTitle    : 'Renovate Dependency Dashboard',
  dependencyDashboardLabels   : ['renovate', 'dashboard'],
  dependencyDashboardApproval : false,
  dependencyDashboardAutoclose: true,

  // ── MR behaviour ─────────────────────────────────────────────────────────
  recreateWhen: 'always',
  rebaseWhen  : 'behind-base-branch',

  // CRITICAL: must be false globally so groupName actually groups packages into one PR
  separateMajorMinor: false,
  separateMinorPatch: false,

  // ── Automerge ─────────────────────────────────────────────────────────────
  platformAutomerge    : false,
  gitLabIgnoreApprovals: true,
  fetchReleaseNotes: false,

  // ── Rate limits ───────────────────────────────────────────────────────────
  prHourlyLimit    : 1000,
  prConcurrentLimit: 1000,

  // ── Enabled managers ──────────────────────────────────────────────────────
  enabledManagers: ['npm', 'maven', 'pip_requirements', 'dockerfile'],

  // ── Ignored paths ─────────────────────────────────────────────────────────
  ignorePaths: [
    '**/node_modules/**', '**/dist/**', '**/build/**',
    '**/target/**', '**/.venv/**', '**/__pycache__/**'
  ],

  packageRules: [

    // =========================================================================
    //  SECTION 1 — ECOSYSTEM GROUPS
    //  Each group produces 3 rules (patch/minor/major) → 3 PRs max per ecosystem
    //  Must come BEFORE catch-all rules
    // =========================================================================

    // ── Python / pip ─────────────────────────────────────────────────────────

    ...ecosystemGroup({
      matchPackageNames: ['langchain', 'langchain-core', 'langchain-community',
                          'langchain-openai', 'langchain-anthropic',
                          'langchain-google-genai', 'langchain-google-vertexai'],
      matchManagers: ['pip_requirements'],
      groupBaseName: 'Python: LangChain',
      extraLabels  : ['langchain', 'ai']
    }),

    ...ecosystemGroup({
      matchPackageNames: ['openai', 'anthropic', 'tiktoken'],
      matchManagers: ['pip_requirements'],
      groupBaseName: 'Python: OpenAI SDK',
      extraLabels  : ['ai']
    }),

    ...ecosystemGroup({
      matchPackageNames: ['transformers', 'tokenizers', 'datasets', 'accelerate',
                          'torch', 'sentence-transformers', 'huggingface-hub'],
      matchManagers: ['pip_requirements'],
      groupBaseName: 'Python: HuggingFace/PyTorch',
      extraLabels  : ['ml']
    }),

    ...ecosystemGroup({
      matchPackageNames: ['boto3', 'botocore', 's3transfer'],
      matchManagers: ['pip_requirements'],
      groupBaseName: 'Python: AWS SDK'
    }),

    ...ecosystemGroup({
      matchPackageNames: ['fastapi', 'uvicorn', 'starlette', 'pydantic', 'pydantic-core'],
      matchManagers: ['pip_requirements'],
      groupBaseName: 'Python: FastAPI',
      extraLabels  : ['fastapi']
    }),

    ...ecosystemGroup({
      matchPackageNames: ['requests', 'httpx', 'aiohttp', 'urllib3', 'certifi'],
      matchManagers: ['pip_requirements'],
      groupBaseName: 'Python: HTTP clients'
    }),

    ...ecosystemGroup({
      matchPackageNames: ['flask', 'flask-cors', 'gunicorn'],
      matchManagers: ['pip_requirements'],
      groupBaseName: 'Python: Flask',
      extraLabels  : ['flask']
    }),

    ...ecosystemGroup({
      matchPackageNames: ['pandas', 'numpy', 'scikit-learn', 'nltk'],
      matchManagers: ['pip_requirements'],
      groupBaseName: 'Python: Data Science'
    }),

    ...ecosystemGroup({
      matchPackageNames: ['pymupdf', 'python-docx', 'docx2txt', 'mammoth', 'pillow', 'openpyxl'],
      matchManagers: ['pip_requirements'],
      groupBaseName: 'Python: Document Processing'
    }),

    ...ecosystemGroup({
      matchPackageNames: ['pymongo', 'aiofiles'],
      matchManagers: ['pip_requirements'],
      groupBaseName: 'Python: Infra libs'
    }),

    // ── npm / Frontend ────────────────────────────────────────────────────────

    ...ecosystemGroup({
      matchPackageNames: ['react', 'react-dom', '@types/react', '@types/react-dom',
                          'react-router', 'react-router-dom'],
      matchManagers: ['npm'],
      groupBaseName: 'npm: React',
      extraLabels  : ['react']
    }),

    ...ecosystemGroup({
      matchPackageNames: ['@reduxjs/toolkit', 'react-redux'],
      matchManagers: ['npm'],
      groupBaseName: 'npm: Redux',
      extraLabels  : ['redux']
    }),

    ...ecosystemGroup({
      matchPackageNames: ['vite', '@vitejs/plugin-react'],
      matchManagers: ['npm'],
      groupBaseName: 'npm: Vite'
    }),

    ...ecosystemGroup({
      matchPackageNames: ['typescript', 'eslint', '@eslint/js',
                          '@typescript-eslint/eslint-plugin', '@typescript-eslint/parser',
                          '@typescript-eslint/type-utils', '@typescript-eslint/utils',
                          'typescript-eslint', 'eslint-plugin-react-hooks',
                          'eslint-plugin-react-refresh'],
      matchManagers: ['npm'],
      groupBaseName: 'npm: TypeScript & ESLint',
      extraLabels  : ['typescript']
    }),

    ...ecosystemGroup({
      matchPackageNames: ['tailwindcss', '@tailwindcss/vite'],
      matchManagers: ['npm'],
      groupBaseName: 'npm: Tailwind CSS'
    }),

    ...ecosystemGroup({
      matchPackageNames: ['@mui/material', '@mui/icons-material', '@emotion/react', '@emotion/styled',
                          '@headlessui/react', '@heroicons/react'],
      matchManagers: ['npm'],
      groupBaseName: 'npm: UI Components',
      extraLabels  : ['ui']
    }),

    ...ecosystemGroup({
      matchPackageNames: ['react-hook-form', 'axios', 'jspdf', 'jspdf-autotable', 'husky', 'prettier'],
      matchManagers: ['npm'],
      groupBaseName: 'npm: Frontend utilities'
    }),

    // ── Maven / Java ──────────────────────────────────────────────────────────

    ...ecosystemGroup({
      matchPackagePatterns: ['^org\\.springframework\\.boot:', '^org\\.springframework\\.security',
                             '^org\\.springframework:'],
      matchManagers: ['maven'],
      groupBaseName: 'Maven: Spring',
      extraLabels  : ['spring']
    }),

    ...ecosystemGroup({
      matchPackagePatterns: ['^org\\.apache\\.tomcat'],
      matchManagers: ['maven'],
      groupBaseName: 'Maven: Tomcat'
    }),

    ...ecosystemGroup({
      matchPackageNames: ['com.auth0:java-jwt', 'io.jsonwebtoken:jjwt-api',
                          'io.jsonwebtoken:jjwt-impl', 'io.jsonwebtoken:jjwt-jackson'],
      matchManagers: ['maven'],
      groupBaseName: 'Maven: JWT & Auth',
      extraLabels  : ['auth']
    }),

    ...ecosystemGroup({
      matchPackageNames: ['io.netty:netty-bom', 'org.projectlombok:lombok',
                          'org.modelmapper:modelmapper',
                          'commons-fileupload:commons-fileupload',
                          'io.opentelemetry:opentelemetry-exporter-otlp'],
      matchManagers: ['maven'],
      groupBaseName: 'Maven: Java utilities'
    }),

    // =========================================================================
    //  SECTION 2 — DOCKERFILE
    //  One PR per update type, separate branch prefix
    // =========================================================================

    ...['patch', 'minor', 'major'].map(type => ({
      matchManagers         : ['dockerfile'],
      matchUpdateTypes      : [type],
      groupName             : `Dockerfile ${type} updates`,
      separateMinorPatch    : false,
      separateMajorMinor    : false,
      automerge             : false,
      prCreation            : 'immediate',
      additionalBranchPrefix: 'docker-',
      labels                : [type, 'dockerfile']
    })),

    // =========================================================================
    //  SECTION 3 — CATCH-ALL
    //  Packages not matched above → one PR per manager per update type
    // =========================================================================

    ...['patch', 'minor', 'major'].map(type => ({
      matchManagers      : ['pip_requirements'],
      matchUpdateTypes   : [type],
      excludePackageNames: PIP_ECOSYSTEM_PACKAGES,
      groupName          : `Python: all other ${type} updates`,
      separateMinorPatch : false,
      separateMajorMinor : false,
      automerge          : false,
      prCreation         : 'immediate',
      labels             : [type]
    })),

    ...['patch', 'minor', 'major'].map(type => ({
      matchManagers      : ['npm'],
      matchUpdateTypes   : [type],
      excludePackageNames: NPM_ECOSYSTEM_PACKAGES,
      groupName          : `npm: all other ${type} updates`,
      separateMinorPatch : false,
      separateMajorMinor : false,
      automerge          : false,
      prCreation         : 'immediate',
      labels             : [type]
    })),

    ...['patch', 'minor', 'major'].map(type => ({
      matchManagers         : ['maven'],
      matchUpdateTypes      : [type],
      excludePackageNames   : MAVEN_ECOSYSTEM_PACKAGES,
      excludePackagePatterns: MAVEN_ECOSYSTEM_PATTERNS,
      groupName             : `Maven: all other ${type} updates`,
      separateMinorPatch    : false,
      separateMajorMinor    : false,
      automerge             : false,
      prCreation            : 'immediate',
      labels                : [type]
    })),

    // =========================================================================
    //  SECTION 4 — REVIEWER ASSIGNMENTS (must be last)
    // =========================================================================
    ...reviewerData.reviewerRules
  ]
};

