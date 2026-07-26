-- CreateEnum
CREATE TYPE "DigestDetailLevel" AS ENUM ('SUBJECT_ONLY', 'ONE_LINE', 'KEY_POINTS');

-- AlterTable
ALTER TABLE "EmailAccount" ADD COLUMN     "digestDetailLevel" "DigestDetailLevel" NOT NULL DEFAULT 'KEY_POINTS';

