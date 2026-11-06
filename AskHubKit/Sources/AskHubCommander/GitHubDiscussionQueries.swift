/// `GitHubDiscussions` が送る GraphQL の問い合わせ
enum DiscussionQueries {
    /// カテゴリは 1 つのリポジトリに 25 個までしか作れないので、ページングしない
    static let repository = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            id
            hasDiscussionsEnabled
            discussionCategories(first: 100) { nodes { id name } }
          }
        }
        """

    static let discussion = """
        query($owner: String!, $name: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $name) {
            discussion(number: $number) {
              id number title body viewerDidAuthor
              comments(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  id body viewerDidAuthor
                  replies(first: 100) { pageInfo { hasNextPage endCursor } nodes { id body viewerDidAuthor } }
                }
              }
            }
          }
        }
        """

    static let replies = """
        query($id: ID!, $after: String) {
          node(id: $id) {
            ... on DiscussionComment {
              replies(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { id body viewerDidAuthor } }
            }
          }
        }
        """

    static let discussions = """
        query($owner: String!, $name: String!, $after: String) {
          repository(owner: $owner, name: $name) {
            discussions(first: 50, after: $after, orderBy: { field: CREATED_AT, direction: DESC }) {
              pageInfo { hasNextPage endCursor }
              nodes { id number body createdAt viewerDidAuthor }
            }
          }
        }
        """

    static let nodes = """
        query($ids: [ID!]!) {
          nodes(ids: $ids) { id }
        }
        """

    static let createDiscussion = """
        mutation($repository: ID!, $category: ID!, $title: String!, $body: String!) {
          createDiscussion(input: { repositoryId: $repository, categoryId: $category, title: $title, body: $body }) {
            discussion { id number }
          }
        }
        """

    static let updateDiscussion = """
        mutation($id: ID!, $title: String!, $body: String!) {
          updateDiscussion(input: { discussionId: $id, title: $title, body: $body }) { discussion { id } }
        }
        """

    static let addComment = """
        mutation($discussion: ID!, $replyTo: ID, $body: String!) {
          addDiscussionComment(input: { discussionId: $discussion, replyToId: $replyTo, body: $body }) { comment { id } }
        }
        """

    static let updateComment = """
        mutation($id: ID!, $body: String!) {
          updateDiscussionComment(input: { commentId: $id, body: $body }) { comment { id } }
        }
        """
}
