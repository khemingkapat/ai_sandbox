#!/bin/bash
# scripts/seed-datasets.sh
# Admin tool to pre-populate starter benchmark datasets in /mnt/storage/datasets.
# Implements the WP3-1-7 specification from docs/CENTRAL_STORAGE.md.

set -e

STORAGE_ROOT="${STORAGE_ROOT:-/mnt/storage}"
if [ ! -d "$STORAGE_ROOT" ] && [ -d "$(pwd)/storage" ]; then
    STORAGE_ROOT="$(pwd)/storage"
fi

DATASETS_DIR="$STORAGE_ROOT/datasets"
VISION_DIR="$DATASETS_DIR/vision"
NLP_DIR="$DATASETS_DIR/nlp"
KAGGLE_DIR="$DATASETS_DIR/kaggle"

TEST_MODE=0
for arg in "$@"; do
    case $arg in
        --test-mode)
            TEST_MODE=1
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--test-mode]"
            echo "  --test-mode: Seeds lightweight benchmark datasets for local dev/testing"
            exit 0
            ;;
    esac
done

echo "📊 Seeding Datasets Repository at $DATASETS_DIR (Test Mode: $TEST_MODE)..."

mkdir -p "$VISION_DIR/mnist" "$VISION_DIR/cifar10" "$NLP_DIR/imdb" "$NLP_DIR/squad" "$KAGGLE_DIR/competitions/titanic" "$KAGGLE_DIR/public"

if [ "$TEST_MODE" -eq 1 ]; then
    echo "📦 [Test Mode] Populating lightweight benchmark samples..."

    # 1. Vision - MNIST sample metadata
    cat <<'EOF' > "$VISION_DIR/mnist/dataset_info.json"
{
  "dataset_name": "mnist",
  "num_classes": 10,
  "train_samples": 60000,
  "test_samples": 10000,
  "input_shape": [28, 28, 1]
}
EOF
    touch "$VISION_DIR/mnist/train-images-idx3-ubyte.sample"

    # 2. Vision - CIFAR-10 sample metadata
    cat <<'EOF' > "$VISION_DIR/cifar10/dataset_info.json"
{
  "dataset_name": "cifar-10",
  "num_classes": 10,
  "classes": ["airplane", "automobile", "bird", "cat", "deer", "dog", "frog", "horse", "ship", "truck"]
}
EOF

    # 3. NLP - IMDb review sample CSV
    cat <<'EOF' > "$NLP_DIR/imdb/train.csv"
review,sentiment
"One of the other reviewers has mentioned that after watching just 1 Oz episode you'll be hooked. They are right.",positive
"A wonderful little production. The filming technique is very unassuming- very old-time-BBC fashion and gives a comforting.",positive
"I thought this was a wonderful way to spend time on a too hot summer weekend, sitting in the air conditioned theater.",positive
"Basically there's a family where a little boy (Jake) thinks there's a zombie in his closet & his parents are fighting all the time.",negative
"Petter Mattei's 'Love in the Time of Money' is a visually stunning film to watch.",positive
EOF

    # 4. NLP - SQuAD sample JSON
    cat <<'EOF' > "$NLP_DIR/squad/train-v2.0.sample.json"
{
  "version": "v2.0",
  "data": [
    {
      "title": "Super_Bowl_50",
      "paragraphs": [
        {
          "qas": [
            {
              "question": "Which NFL team won Super Bowl 50?",
              "id": "56be4db0acb8001400a502ec",
              "answers": [{"text": "Denver Broncos", "answer_start": 177}],
              "is_impossible": false
            }
          ],
          "context": "Super Bowl 50 was an American football game to determine the champion of the National Football League (NFL) for the 2015 season. The American Football Conference (AFC) champion Denver Broncos defeated the National Football Conference (NFC) champion Carolina Panthers 24–10."
        }
      ]
    }
  ]
}
EOF

    # 5. Kaggle - Titanic competition data
    cat <<'EOF' > "$KAGGLE_DIR/competitions/titanic/train.csv"
PassengerId,Survived,Pclass,Name,Sex,Age,SibSp,Parch,Ticket,Fare,Cabin,Embarked
1,0,3,"Braund, Mr. Owen Harris",male,22,1,0,A/5 21171,7.25,,S
2,1,1,"Cumings, Mrs. John Bradley (Florence Briggs Thayer)",female,38,1,0,PC 17599,71.2833,C85,C
3,1,3,"Heikkinen, Miss. Laina",female,26,0,0,STON/O2. 3101282,7.925,,S
4,1,1,"Futrelle, Mrs. Jacques Heath (Lily May Peel)",female,35,1,0,113803,53.1,C123,S
5,0,3,"Allen, Mr. William Henry",male,35,0,0,373450,8.05,,S
EOF

    cat <<'EOF' > "$KAGGLE_DIR/competitions/titanic/test.csv"
PassengerId,Pclass,Name,Sex,Age,SibSp,Parch,Ticket,Fare,Cabin,Embarked
892,3,"Kelly, Mr. James",male,34.5,0,0,330911,7.8292,,Q
893,3,"Wilkes, Mrs. James (Ellen Needs)",female,47,1,0,363272,7,,S
894,2,"Myles, Mr. Thomas Francis",male,62,0,0,240276,9.6875,,Q
EOF

fi

# Hardening permissions to read-only for students
echo "🔐 Locking dataset permissions to root:root 755 (dirs) and 644 (files)..."
chown -R 0:0 "$DATASETS_DIR"
find "$DATASETS_DIR" -type d -exec chmod 755 {} +
find "$DATASETS_DIR" -type f -exec chmod 644 {} +

echo "✅ Datasets Repository successfully seeded at $DATASETS_DIR."
