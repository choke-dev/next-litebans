# ============================================
# Stage 1: Dependencies
# Install all dependencies (production + dev)
# ============================================
FROM node:20-alpine AS deps

# Install libc6-compat for Alpine compatibility with native modules
RUN apk add --no-cache libc6-compat

WORKDIR /app

# Copy package files for dependency installation
# Copying these first enables Docker layer caching - dependencies only reinstall when these files change
COPY package.json package-lock.json ./

# Install ALL dependencies (including devDependencies)
# Required for: TypeScript compilation, Prisma generation, Next.js build
# Using npm ci for faster, deterministic, clean installs
RUN npm ci

# ============================================
# Stage 2: Builder
# Generate Prisma client and build Next.js
# ============================================
FROM node:20-alpine AS builder

WORKDIR /app

# Copy dependencies from deps stage
COPY --from=deps /app/node_modules ./node_modules

# Copy all source files needed for build
COPY . .

# CRITICAL BUILD ORDER:
# 1. Generate Prisma Client FIRST (before Next.js build)
#    - Next.js build imports @prisma/client
#    - Build will fail if Prisma client not generated
# 2. Build Next.js application SECOND
#    - Compiles TypeScript
#    - Optimizes React components
#    - Generates production server

# Step 1: Generate Prisma Client
RUN npx prisma generate

# Step 2: Build Next.js application
# This will use the generated Prisma client
RUN npm run build

# ============================================
# Stage 3: Runner (Production)
# Minimal production image with only runtime dependencies
# ============================================
FROM node:20-alpine AS runner

WORKDIR /app


# Disable Next.js telemetry in production
ENV NEXT_TELEMETRY_DISABLED=1

# Create non-root user for security
# Running as non-root prevents privilege escalation attacks
RUN addgroup --system --gid 1001 nodejs && \
adduser --system --uid 1001 nextjs

# Copy necessary files from builder stage
# Only copy what's needed for production runtime

# Copy deps
COPY --from=deps /app/node_modules ./node_modules

# Copy package files
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/package-lock.json ./package-lock.json

# Copy Next.js configuration
COPY --from=builder /app/next.config.mjs ./next.config.mjs

# Copy static assets
COPY --from=builder /app/public ./public

# Copy i18n language files
COPY --from=builder /app/language ./language

# Copy site configuration
COPY --from=builder /app/config ./config

# Copy Prisma schema (for reference and runtime)
COPY --from=builder /app/prisma ./prisma

# Install ONLY production dependencies
# This significantly reduces image size by excluding dev dependencies
RUN npm ci --omit=dev && \
    npm cache clean --force

# Copy built Next.js application
# The .next directory contains the optimized production build
COPY --from=builder --chown=nextjs:nodejs /app/.next ./.next

# Copy generated Prisma Client
# This is critical - the Prisma client generated during build must be available at runtime
COPY --from=builder --chown=nextjs:nodejs /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=builder --chown=nextjs:nodejs /app/node_modules/@prisma ./node_modules/@prisma

# Set correct permissions for nextjs user
RUN chown -R nextjs:nodejs /app

# Switch to non-root user
USER nextjs

# Expose port 3000
# Map to desired host port via: docker run -p 8080:3000
EXPOSE 3000

# Health check to verify application is running
# Checks every 30 seconds, with 3 retries before marking unhealthy
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000', (r) => {process.exit(r.statusCode === 200 ? 0 : 1)})"

# Start Next.js production server
# This runs: next start
CMD ["npm", "start"]